import Foundation
import SwiftData

enum MailProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case gmail
    case outlook
}

enum EmailAnalysisState: String, Codable, CaseIterable {
    case unanalyzed
    case analyzing
    case analyzed
    case failed
}

/// 로컬 전용 이메일 메시지 모델.
///
/// ⚠️ 반드시 AppDataContainer.emailContainer에만 저장 — iCloud / CloudKit 절대 금지.
/// 본문(body)이 기기 밖으로 나가지 않도록 appSchema와 별도 스키마로 관리됩니다.
@Model
final class EmailMessage {
    var id: String = ""           // 기존 Gmail message id 호환용 로컬 식별자
    var threadID: String = ""
    var subject: String = ""
    var from: String = ""
    var snippet: String = ""
    var body: String = ""         // 세니타이징된 평문 본문 — 온디바이스 전용
    var htmlBody: String? = nil   // 원본 HTML 본문 (WKWebView 렌더링용) — 온디바이스 전용
    var receivedAt: Date = Date.distantPast
    var isRead: Bool = false
    var providerRawValue: String = MailProvider.gmail.rawValue
    var rawMessageID: String = ""
    var labelIDs: [String] = []
    var isInInbox: Bool = false
    var outlookInferenceClassificationRawValue: String = ""
    var providerCategoryNames: [String] = []
    var providerFolderID: String = ""
    /// Opaque account namespace. Empty is a legacy row awaiting safe hydration.
    var sourceAccountNamespace: String = ""
    /// Durable local-only analysis state. It is invalidated whenever the body
    /// representation changes, so an old summary is never shown for new mail.
    var analysisStateRaw: String = EmailAnalysisState.unanalyzed.rawValue
    var analysisSummary: String = ""
    var analysisDetail: String = ""
    var analysisKeyPoints: [String] = []
    var analysisActionItems: [String] = []
    var analysisError: String = ""
    var analyzedBodyFingerprint: String = ""
    var analyzedAt: Date? = nil
    /// Bump when the structured summary prompt or model contract changes.
    var analysisVersion: Int = 0

    var provider: MailProvider {
        get { MailProvider(rawValue: providerRawValue) ?? .gmail }
        set { providerRawValue = newValue.rawValue }
    }

    var providerMessageID: String {
        rawMessageID.isEmpty ? id : rawMessageID
    }

    var localListID: String {
        sourceAccountNamespace.isEmpty
            ? "\(provider.rawValue):\(providerMessageID)"
            : "\(provider.rawValue):\(sourceAccountNamespace):\(providerMessageID)"
    }

    var todoSourceRef: String {
        switch provider {
        case .gmail:
            return providerMessageID
        case .outlook:
            return "outlook:\(providerMessageID)"
        }
    }

    var gmailInboxCategories: Set<GmailInboxCategory> {
        guard provider == .gmail else { return [] }
        return GmailInboxCategory.resolveAll(labelIDs: labelIDs)
    }

    var outlookInboxClassification: OutlookInboxClassification {
        OutlookInboxClassification(
            rawValue: outlookInferenceClassificationRawValue.lowercased()
        ) ?? .other
    }

    var analysisState: EmailAnalysisState {
        get { EmailAnalysisState(rawValue: analysisStateRaw) ?? .unanalyzed }
        set { analysisStateRaw = newValue.rawValue }
    }

    init(
        id: String,
        threadID: String = "",
        subject: String = "",
        from: String = "",
        snippet: String = "",
        body: String = "",
        htmlBody: String? = nil,
        receivedAt: Date = Date.distantPast,
        isRead: Bool = false,
        provider: MailProvider = .gmail,
        rawMessageID: String? = nil,
        labelIDs: [String] = [],
        isInInbox: Bool = false,
        outlookInferenceClassificationRawValue: String = "",
        providerCategoryNames: [String] = [],
        providerFolderID: String = "",
        sourceAccountNamespace: String = ""
    ) {
        self.id = id
        self.threadID = threadID
        self.subject = subject
        self.from = from
        self.snippet = snippet
        self.body = body
        self.htmlBody = htmlBody
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.providerRawValue = provider.rawValue
        self.rawMessageID = rawMessageID ?? id
        self.labelIDs = labelIDs
        self.isInInbox = isInInbox
        self.outlookInferenceClassificationRawValue = outlookInferenceClassificationRawValue
        self.providerCategoryNames = providerCategoryNames
        self.providerFolderID = providerFolderID
        self.sourceAccountNamespace = sourceAccountNamespace
    }
}

enum GmailInboxCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case primary
    case promotions
    case social
    case updates
    case forums

    var id: String { rawValue }

    var gmailLabelID: String {
        switch self {
        case .primary: "CATEGORY_PERSONAL"
        case .promotions: "CATEGORY_PROMOTIONS"
        case .social: "CATEGORY_SOCIAL"
        case .updates: "CATEGORY_UPDATES"
        case .forums: "CATEGORY_FORUMS"
        }
    }

    var explanation: String {
        explanation(language: .current)
    }

    func explanation(language: AppLanguage) -> String {
        let values: (String, String)
        switch self {
        case .primary:
            values = ("아는 사람이 보낸 메일 및 다른 카테고리에 속하지 않은 메일", "Mail from people you know and mail that does not fit another category")
        case .promotions:
            values = ("특가, 혜택 등 홍보성 메일", "Promotional mail about deals and offers")
        case .social:
            values = ("소셜 네트워크 및 미디어 공유 서비스에서 보낸 메일", "Mail from social networks and media-sharing services")
        case .updates:
            values = ("자동 확인 메일, 알림, 명세서, 리마인더", "Automated confirmations, notifications, statements, and reminders")
        case .forums:
            values = ("온라인 그룹, 토론 게시판, 메일링 리스트에서 온 메일", "Mail from online groups, discussion boards, and mailing lists")
        }
        return language == .english ? values.1 : values.0
    }

    var title: String {
        title(language: .current)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .primary: language == .english ? "Primary" : "기본"
        case .promotions: language == .english ? "Promotions" : "프로모션"
        case .social: language == .english ? "Social" : "소셜"
        case .updates: language == .english ? "Updates" : "업데이트"
        case .forums: language == .english ? "Forums" : "포럼"
        }
    }

    var systemImage: String {
        switch self {
        case .primary: "tray.full"
        case .promotions: "tag"
        case .social: "person.2"
        case .updates: "info.circle"
        case .forums: "bubble.left.and.bubble.right"
        }
    }

    static func resolveAll(labelIDs: [String]) -> Set<GmailInboxCategory> {
        let labels = Set(labelIDs)
        let categories = Set(allCases.filter { labels.contains($0.gmailLabelID) })
        return categories.isEmpty ? [.primary] : categories
    }
}

enum OutlookInboxClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case focused
    case other
}

struct MailboxMessageMetadata: Sendable {
    let provider: MailProvider
    let providerMessageID: String
    let sourceAccountNamespace: String = ""
    let threadID: String
    let subject: String
    let from: String
    let snippet: String
    let receivedAt: Date
    let isRead: Bool
    let isInInbox: Bool
    let gmailLabelIDs: [String]
    let outlookInferenceClassificationRawValue: String
    let providerCategoryNames: [String]
    let providerFolderID: String
}

struct MailboxPage: Sendable {
    let messages: [MailboxMessageMetadata]
    let nextCursor: String?
}

struct MailboxMessageContent: Sendable {
    let metadata: MailboxMessageMetadata
    let body: String
    let htmlBody: String
}

struct EmailMessageKey: Hashable, Sendable {
    let providerRawValue: String
    let sourceAccountNamespace: String
    let providerMessageID: String

    init(_ email: EmailMessage) {
        providerRawValue = email.providerRawValue
        sourceAccountNamespace = email.sourceAccountNamespace
        providerMessageID = email.providerMessageID
    }

    init(providerRawValue: String, sourceAccountNamespace: String = "", providerMessageID: String) {
        self.providerRawValue = providerRawValue
        self.sourceAccountNamespace = sourceAccountNamespace
        self.providerMessageID = providerMessageID
    }
}

enum EmailAnalysisLookbackPolicy {
    nonisolated static let lookbackSettingKey = "pieroot.todo.emailLookbackDays"
    nonisolated static let defaultLookbackDays = 3
    nonisolated static let lookbackRange = 1...30

    nonisolated static func normalizedLookbackDays(_ value: Int) -> Int {
        guard value > 0 else { return defaultLookbackDays }
        return min(max(value, lookbackRange.lowerBound), lookbackRange.upperBound)
    }

    nonisolated static func storedLookbackDays() -> Int {
        SettingsStore.emailAnalysisLookbackDays()
    }

    @MainActor
    static func saveLookbackDays(_ value: Int) {
        SettingsStore.shared.set(
            lookbackSettingKey,
            value: normalizedLookbackDays(value)
        )
    }

    nonisolated static func cutoff(
        now: Date = Date(),
        lookbackDays: Int
    ) -> Date {
        now.addingTimeInterval(
            -Double(normalizedLookbackDays(lookbackDays)) * 24 * 60 * 60
        )
    }
}

enum EmailCacheReconciler {
    static func removeCacheOnly(_ email: EmailMessage, from context: ModelContext) {
        context.delete(email)
    }
}

struct MailboxPagingState: Equatable {
    var nextCursor: String?
    var totalInboxCount: Int?
    var hasLoadedInitialPage: Bool = false
    var isLoadingPage: Bool = false
    var isReconcilingIndex: Bool = false
    var pageErrorMessage: String?
    var indexWarningMessage: String?

    var canLoadMore: Bool {
        hasLoadedInitialPage && nextCursor != nil
    }
}
