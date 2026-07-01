import Foundation
import SwiftData

enum MailProvider: String, Codable, CaseIterable {
    case gmail
    case outlook
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

    var provider: MailProvider {
        get { MailProvider(rawValue: providerRawValue) ?? .gmail }
        set { providerRawValue = newValue.rawValue }
    }

    var providerMessageID: String {
        rawMessageID.isEmpty ? id : rawMessageID
    }

    var localListID: String {
        "\(provider.rawValue):\(providerMessageID)"
    }

    var todoSourceRef: String {
        switch provider {
        case .gmail:
            return providerMessageID
        case .outlook:
            return "outlook:\(providerMessageID)"
        }
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
        rawMessageID: String? = nil
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
    }
}
