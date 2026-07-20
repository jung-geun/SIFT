import Foundation

struct GmailProfileResponse: Decodable {
    let emailAddress: String
    let historyId: String
}

enum GmailHistoryError: Error {
    case expiredCursor
}

enum GmailMetadataOutcome: Sendable {
    case message(GmailMessage)
    case notFound(id: String)
}

struct GmailHistoryListResponse: Decodable {
    let history: [GmailHistoryRecord]?
    let historyId: String
    let nextPageToken: String?
}

struct GmailHistoryRecord: Decodable {
    let id: String
    let messagesAdded: [GmailHistoryMessage]?
    let messagesDeleted: [GmailHistoryMessage]?
    let labelsAdded: [GmailHistoryMessage]?
    let labelsRemoved: [GmailHistoryMessage]?
}

struct GmailHistoryMessage: Decodable {
    let message: GmailHistoryMessageID
}

struct GmailHistoryMessageID: Decodable {
    let id: String
}

struct GmailSyncCursorStore {
    private static let keyPrefix = "pieroot.todo.gmail.historyID."

    static func historyID(for account: String) -> String? {
        UserDefaults.standard.string(forKey: keyPrefix + account.lowercased())
    }

    static func setHistoryID(_ historyID: String, for account: String) {
        UserDefaults.standard.set(historyID, forKey: keyPrefix + account.lowercased())
    }

    static func clearHistoryID(for account: String) {
        UserDefaults.standard.removeObject(forKey: keyPrefix + account.lowercased())
    }
}
