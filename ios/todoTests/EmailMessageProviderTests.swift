import Foundation
import Testing
@testable import todo

@Suite("EmailMessage provider helpers")
struct EmailMessageProviderTests {
    @Test("기존 Gmail 스타일 메시지는 Gmail 기본값을 유지한다")
    func testGmailDefaults() {
        let email = EmailMessage(
            id: "gmail-raw",
            threadID: "thread-1",
            subject: "Subject",
            from: "sender@example.com",
            snippet: "snippet",
            body: "body",
            htmlBody: nil,
            receivedAt: Date()
        )

        #expect(email.provider == .gmail)
        #expect(email.providerMessageID == "gmail-raw")
        #expect(email.todoSourceRef == "gmail-raw")
    }

    @Test("Outlook 메시지는 provider-safe 식별자를 만든다")
    func testOutlookProviderIdentifiers() {
        let email = EmailMessage(
            id: "outlook-raw",
            threadID: "thread-2",
            subject: "Subject",
            from: "sender@example.com",
            snippet: "snippet",
            body: "body",
            htmlBody: nil,
            receivedAt: Date(),
            provider: .outlook,
            rawMessageID: "outlook-raw"
        )

        #expect(email.provider == .outlook)
        #expect(email.localListID == "outlook:outlook-raw")
        #expect(email.todoSourceRef == "outlook:outlook-raw")
    }
}
