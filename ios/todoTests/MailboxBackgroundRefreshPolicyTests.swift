import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Independent foreground and OS background mail policy")
@MainActor
struct MailboxBackgroundRefreshPolicyTests {
    @Test("foreground cadence is 30–60 seconds without promising an iOS background cadence")
    func independentCadences() {
        #expect((30...60).contains(MailboxPagingPolicy.pollInterval))
        #expect(MailboxPagingPolicy.updatesMinimumInterval <= MailboxPagingPolicy.pollInterval)
        #expect(MailboxPagingPolicy.backgroundRefreshInterval >= 15 * 60)
        #expect(MailboxPagingPolicy.bodyPrefetchBatchSize == 8)
        #expect(MailboxPagingPolicy.maxUpdateDrainPages == 10)
    }

    @Test("legacy daily-hour and recent cooldown values remain intact but cannot block eligible complete-body analysis")
    func legacyScheduleDoesNotGateQueue() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "MailboxPolicy-\(UUID().uuidString)")!
        defaults.set("user@gmail.com", forKey: "pieroot.todo.imap.account")
        defaults.set(true, forKey: "pieroot.todo.emailAutoAnalysisEnabled")
        defaults.set(23, forKey: "pieroot.todo.emailRefreshHour")
        let legacyRun = Date().timeIntervalSince1970
        defaults.set(legacyRun, forKey: "pieroot.todo.lastLLMAutomationDate")
        let email = EmailMessage(
            id: "queued", subject: "Plan", body: "The complete plan is ready.",
            rawMessageID: "queued", isInInbox: true, sourceAccountNamespace: "user@gmail.com"
        )
        email.bodyContentVersion = 1
        context.insert(email)
        try context.save()
        let orchestrator = EmailAutomationOrchestrator(
            defaults: defaults, makeContext: { context },
            analysisService: EmailMessageAnalysisService(foundationModelsEnabledProvider: { false }),
            accountAvailable: { _, _ in true }, batteryAllowsAnalysis: { true }
        )
        #expect(await orchestrator.runIfEligible(context: context))
        #expect(EmailAnalysisContract.isCurrentAnalysis(email))
        #expect(defaults.integer(forKey: "pieroot.todo.emailRefreshHour") == 23)
        #expect(defaults.double(forKey: "pieroot.todo.lastLLMAutomationDate") == legacyRun)
        #expect(!(await orchestrator.runIfEligible(context: context)))
    }
}
