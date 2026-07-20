import Foundation
import Testing
@testable import todo

@Suite("EmailService.makeManualTodo")
struct EmailManualTodoTests {

    private func message(
        id: String,
        threadID: String = "thread-123",
        messageID: String = "<msg-123@example.com>",
        subject: String = "",
        from: String = "김개발 <dev@example.com>",
        snippet: String = "이메일 요약",
        body: String = "본문 내용"
    ) -> GmailMessage {
        GmailMessage(
            id: id,
            threadID: threadID,
            messageID: messageID,
            subject: subject,
            from: from,
            snippet: snippet,
            body: body,
            htmlBody: nil,
            receivedAt: Date(),
            labelIds: [],
            isBulk: false
        )
    }

    @Test("makeManualTodo fallback는 제목 미입력 시 기본 제목을 채운다")
    func testFallbackTitleAndNotes() async {
        let todo = await EmailService.shared.makeManualTodo(
            from: message(id: "msg-no-subject", subject: "", from: "\"홍길동\" <hong@sample.com>", snippet: "업무 메모가 비어있지 않음"),
            allowFoundationModels: false,
            language: .korean
        )

        #expect(todo.title == "메일 확인")
        #expect(todo.notes.contains("[메일 요약]"))
        #expect(todo.notes.contains("[발신자] 홍길동"))
        #expect(todo.sourceRef == "msg-no-subject")
        #expect(todo.sourceMessageID == "<msg-123@example.com>")
        #expect(todo.sourceThreadID == "thread-123")
        #expect(todo.sourceSender == "홍길동")
        #expect(todo.sourceSenderEmail == "hong@sample.com")
    }

    @Test("makeManualTodo fallback는 마감일이 없으면 dueDate가 nil")
    func testFallbackHasNoDueDateWhenMissing() async {
        let todo = await EmailService.shared.makeManualTodo(
            from: message(
                id: "msg-no-deadline",
                subject: "일정 안내",
                from: "notice@example.com",
                snippet: "공지사항",
                body: "단순 안내 메일입니다."
            ),
            allowFoundationModels: false
        )

        #expect(todo.dueDate == nil)
        #expect(todo.sourceMessageID == "<msg-123@example.com>")
        #expect(todo.sourceThreadID == "thread-123")
        #expect(todo.sourceSender == "notice")
        #expect(todo.sourceSenderEmail == "notice@example.com")
    }
}
