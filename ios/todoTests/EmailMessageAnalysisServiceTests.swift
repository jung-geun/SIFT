import Foundation
import SwiftData
import Testing
@testable import todo

@MainActor
private final class SuspendedEmailSummaryProvider {
    private var continuation: CheckedContinuation<EmailSummaryResult, Never>?

    func summarize(
        subject: String,
        sender: String,
        body: String
    ) async throws -> EmailSummaryResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume(with result: EmailSummaryResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
@Suite("Email message analysis service", .serialized)
struct EmailMessageAnalysisServiceTests {
    @Test("본문이 분석 중 변경되면 이전 결과를 게시하지 않는다")
    func testSourceMutationWhileSummarizerIsSuspended() async throws {
        let schema = Schema([EmailMessage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "analysis-race",
            subject: "original subject",
            body: "original body",
            provider: .gmail,
            rawMessageID: "analysis-race",
            isInInbox: true
        )
        context.insert(email)
        try context.save()

        let provider = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            summaryProvider: provider.summarize
        )
        let analysisTask = Task {
            await service.analyze(email, context: context)
        }
        await provider.waitUntilSuspended()
        #expect(email.analysisState == .analyzing)

        email.subject = "updated subject"
        email.body = "updated body"
        try context.save()
        provider.resume(
            with: EmailSummaryResult(
                summary: "stale summary",
                keyPoints: ["stale point"],
                actionItems: ["stale action"]
            )
        )
        await analysisTask.value

        #expect(email.analysisState == .unanalyzed)
        #expect(email.analysisSummary.isEmpty)
        #expect(email.analysisKeyPoints.isEmpty)
        #expect(email.analysisActionItems.isEmpty)
        #expect(email.analyzedBodyFingerprint.isEmpty)
        #expect(email.analysisVersion == 0)
        #expect(!context.hasChanges)
    }
}
