import CryptoKit
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
        body: String,
        language _: AppLanguage
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
private final class EmailModelGateState {
    var enabled: Bool
    var available: Bool

    init(enabled: Bool, available: Bool = false) {
        self.enabled = enabled
        self.available = available
    }
}

@MainActor
private final class CancellableEmailSummaryProvider {
    private(set) var started = false

    func summarize(
        subject _: String,
        sender _: String,
        body _: String,
        language _: AppLanguage
    ) async throws -> EmailSummaryResult {
        started = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return EmailSummaryResult(summary: "unexpected", keyPoints: [], actionItems: [])
    }
}

@MainActor
@Suite("Email message analysis service", .serialized)
struct EmailMessageAnalysisServiceTests {

    @Test("Cached disabled and unavailable summaries upgrade when AFM becomes eligible", arguments: [false, true])
    func testIndependentAFMGates(initiallyEnabled: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "gates", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "gates", isInInbox: true)
        email.bodyContentVersion = 1
        context.insert(email)
        let state = EmailModelGateState(enabled: initiallyEnabled)
        var calls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                calls += 1
                return EmailSummaryResult(summary: "Apple summary", keyPoints: ["Friday"], actionItems: ["Review plan"])
            },
            foundationModelsEnabledProvider: { state.enabled },
            foundationModelsAvailabilityProvider: { state.available }
        )
        try await service.analyze(email, context: context)
        let localSummary = EmailAnalysisContract.deterministicSummary(subject: email.subject, body: email.body).summary
        #expect(email.analysisSummary == localSummary)
        #expect(email.analysisFailureReasonRaw == (initiallyEnabled ? RuleFallbackReason.unavailable : .providerDisabled).rawValue)
        #expect(calls == 0)
        state.enabled = true
        state.available = true
        try await service.analyze(email, context: context)
        #expect(email.analysisSummary == "Apple summary")
        #expect(email.analysisKeyPoints == ["Friday"])
        #expect(email.analysisActionItems == ["Review plan"])
        #expect(email.analysisFailureReasonRaw == nil)
        #expect(calls == 1)
        try await service.analyze(email, context: context)
        #expect(calls == 1)
    }

    @Test("AFM execution errors retain deterministic analysis and reason")
    func testAFMErrorFallsBack() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "error", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "error", isInInbox: true)
        email.bodyContentVersion = 1
        context.insert(email)
        var summaryCalls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                summaryCalls += 1
                throw NSError(domain: "test", code: 1)
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        try await service.analyze(email, context: context)
        #expect(email.analysisState == .analyzed)
        #expect(email.analysisSummary == EmailAnalysisContract.deterministicSummary(subject: email.subject, body: email.body).summary)
        #expect(email.analysisFailureReasonRaw == RuleFallbackReason.providerExecutionFailed.rawValue)
        #expect(EmailAnalysisContract.todoCandidate(for: email) == nil)
        try await service.analyze(email, context: context)
        #expect(summaryCalls == 1)
        #expect(email.analysisFailureReasonRaw == RuleFallbackReason.providerExecutionFailed.rawValue)
    }


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
        email.bodyContentVersion = 1
        context.insert(email)
        try context.save()

        let provider = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: provider.summarize,
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        let analysisTask = Task {
            try? await service.analyze(email, context: context)
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
    @Test("분석 취소는 실패 상태를 저장하지 않는다")
    func testCancellationDoesNotPersistFailure() async throws {
        let schema = Schema([EmailMessage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "analysis-cancel",
            subject: "subject",
            body: "body",
            provider: .gmail,
            rawMessageID: "analysis-cancel",
            isInInbox: true
        )
        email.bodyContentVersion = 1
        context.insert(email)
        try context.save()

        let provider = CancellableEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: provider.summarize,
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        let analysisTask = Task { () -> Error? in
            do {
                try await service.analyze(email, context: context)
                return nil
            } catch {
                return error
            }
        }
        while !provider.started {
            await Task.yield()
        }
        analysisTask.cancel()
        let cancellationError = await analysisTask.value

        #expect(email.analysisState == .unanalyzed)
        #expect(email.analysisError.isEmpty)
        #expect(cancellationError is CancellationError)
        #expect(email.analysisSummary.isEmpty)
        #expect(!context.hasChanges)
    }

    @Test("canceled analysis does not access a deleted source row")
    func testCancellationAfterSourceDeletionDoesNotTouchDetachedModel() async throws {
        let schema = Schema([EmailMessage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "analysis-deleted",
            subject: "subject",
            body: "body",
            provider: .gmail,
            rawMessageID: "analysis-deleted",
            isInInbox: true
        )
        email.bodyContentVersion = 1
        context.insert(email)
        try context.save()

        let provider = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: provider.summarize,
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        let analysisTask = Task { () -> Error? in
            do {
                try await service.analyze(email, context: context)
                return nil
            } catch {
                return error
            }
        }
        await provider.waitUntilSuspended()

        context.delete(email)
        try context.save()
        analysisTask.cancel()
        provider.resume(
            with: EmailSummaryResult(
                summary: "must not be written",
                keyPoints: ["must not be written"],
                actionItems: []
            )
        )

        #expect(await analysisTask.value is CancellationError)
        #expect(try context.fetch(FetchDescriptor<EmailMessage>()).isEmpty)
    }

    @Test("AFM이 선택되면 메일 요약 결과를 규칙 기반 요약 대신 저장한다")
    func testAFMRoutePersistsProviderSummary() async throws {
        let schema = Schema([EmailMessage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "analysis-afm",
            subject: "프로젝트 일정",
            body: "금요일까지 검토 의견을 회신해 주세요.",
            provider: .gmail,
            rawMessageID: "analysis-afm",
            isInInbox: true
        )
        email.bodyContentVersion = 1
        context.insert(email)
        try context.save()

        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { subject, sender, body, language in
                #expect(subject == "프로젝트 일정")
                #expect(sender.isEmpty)
                #expect(body == "금요일까지 검토 의견을 회신해 주세요.")
                #expect(language == .korean)
                return EmailSummaryResult(
                    summary: "금요일까지 프로젝트 일정 검토 의견 회신이 필요합니다.",
                    keyPoints: ["기한: 금요일"],
                    actionItems: ["검토 의견 회신"]
                )
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )

        try await service.analyze(email, context: context, language: .korean)

        #expect(email.analysisSummary == "금요일까지 프로젝트 일정 검토 의견 회신이 필요합니다.")
        #expect(email.analysisKeyPoints == ["기한: 금요일"])
        #expect(email.analysisActionItems == ["검토 의견 회신"])
        #expect(email.analysisFailureReasonRaw == nil)
        #expect(email.analysisVersion == EmailAnalysisContract.summaryContractVersion)
    }

    @Test("현재 AFM이 사용 가능해지면 저장된 규칙 기반 요약을 다시 분석한다")
    func testAFMRetriesCurrentRuleFallback() async throws {
        let schema = Schema([EmailMessage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "analysis-afm-retry",
            subject: "프로젝트 일정",
            body: "금요일까지 검토 의견을 회신해 주세요.",
            provider: .gmail,
            rawMessageID: "analysis-afm-retry",
            isInInbox: true
        )
        email.bodyContentVersion = 1
        context.insert(email)
        email.analysisState = .analyzed
        email.analysisSummary = "규칙 기반 기존 요약"
        email.analysisFailureReasonRaw = RuleFallbackReason.noProviderOptIn.rawValue
        email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
            subject: email.subject,
            body: email.body
        )
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        try context.save()

        var providerCalls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                providerCalls += 1
                return EmailSummaryResult(
                    summary: "AFM으로 갱신한 요약",
                    keyPoints: [],
                    actionItems: []
                )
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )

        try await service.analyze(email, context: context, language: .korean)

        #expect(providerCalls == 1)
        #expect(email.analysisSummary == "AFM으로 갱신한 요약")
        #expect(email.analysisFailureReasonRaw == nil)
    }

    @Test("Available AFM upgrades cached legacy provider fallbacks", arguments: [RuleFallbackReason.providerNotApplicable, .modelNotLoaded, .credentialMissing, .consentMissing])
    func testAFMRetriesLegacyProviderFallback(reason: RuleFallbackReason) async throws {
        let schema = Schema([EmailMessage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let email = EmailMessage(
            id: "analysis-laya-to-afm",
            subject: "Project deadline",
            body: "Please review the plan by Friday.",
            provider: .gmail,
            rawMessageID: "analysis-laya-to-afm",
            isInInbox: true
        )
        email.bodyContentVersion = 1
        context.insert(email)
        email.analysisState = .analyzed
        email.analysisSummary = "Cached rules summary"
        email.analysisFailureReasonRaw = reason.rawValue
        email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(
            subject: email.subject,
            body: email.body
        )
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        try context.save()

        var providerCalls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                providerCalls += 1
                return EmailSummaryResult(summary: "AFM summary", keyPoints: [], actionItems: [])
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        try await service.analyze(email, context: context, language: .english)

        #expect(providerCalls == 1)
        #expect(email.analysisSummary == "AFM summary")
        #expect(email.analysisFailureReasonRaw == nil)
    }

    @Test("규칙 기반 요약은 링크와 이미지 잡음을 제외하고 한국어 본문을 정리한다")
    func testDeterministicSummaryPreservesShortKoreanSentences() {
        let result = EmailAnalysisContract.deterministicSummary(
            subject: "주문 확인",
            body: """
            Napkin AI Coloured Logo https://cdn.example.com/logo.png
            주문이 정상적으로 접수되었습니다.
            배송 정보는 내일 다시 안내드립니다.
            """
        )

        #expect(result.summary.contains("주문이 정상적으로 접수되었습니다"))
        #expect(result.summary.contains("배송 정보는 내일 다시 안내드립니다"))
        #expect(!result.summary.contains("https://"))
    }

    @Test("규칙 기반 요약은 본문 미리보기와 후속 핵심 문장을 분리한다")
    func testDeterministicSummarySeparatesKeyPoints() {
        let result = EmailAnalysisContract.deterministicSummary(
            subject: "Napkin Slides",
            body: """
            Napkin AI Coloured Logo https://cdn.example.com/logo.png
            We built Napkin because ideas deserve to be seen, not just read.
            Introducing Napkin Slides so you can make presentations you are proud of.
            Slides are available today as part of your existing subscription.
            """
        )

        #expect(result.summary.contains("We built Napkin"))
        #expect(result.summary.contains("Introducing Napkin Slides"))
        #expect(result.keyPoints == ["Slides are available today as part of your existing subscription"])
    }

    @Test("규칙 기반 요약은 본문의 이스케이프된 줄바꿈을 문장 경계로 처리한다")
    func testDeterministicSummaryUnescapesLiteralNewlines() {
        let result = EmailAnalysisContract.deterministicSummary(
            subject: "알림",
            body: #"첫 번째 안내 문장입니다.\n두 번째 중요한 문장입니다.\n세 번째 후속 안내 문장입니다."#
        )

        #expect(result.summary == "첫 번째 안내 문장입니다 두 번째 중요한 문장입니다")
        #expect(result.keyPoints == ["세 번째 후속 안내 문장입니다"])
        #expect(!result.summary.contains(#"\n"#))
    }

    @Test("규칙 기반 요약은 이스케이프된 줄바꿈이 있는 캘린더 초대를 행동 중심으로 정리한다")
    func testDeterministicSummarySynthesizesCalendarInvitation() {
        let result = EmailAnalysisContract.deterministicSummary(
            subject: "공유 캘린더 'RTX6000 스케줄달력'에 참여하려면 초대를 수락하세요",
            body: #"김청해님이 캘린더를 공유했습니다\n\n김청해 님이 'RTX6000 스케줄달력' 캘린더에 대한 변경사항을 적용하고 공유를 관리할 수 있습니다 권한으로 나를 초대했습니다.\n\n이 공유 캘린더에 참여하려면 초대를 수락하세요. 언제든지 캘린더를 숨기거나 삭제할 수 있습니다."#
        )

        #expect(result.summary.contains("RTX6000 스케줄달력"))
        #expect(result.actionItems.isEmpty)
        #expect(!result.summary.contains(#"\n"#))
    }

    @Test("규칙 기반 요약은 영어 캘린더 초대의 스마트 따옴표 이름을 보존한다")
    func testDeterministicSummarySynthesizesEnglishCalendarInvitation() {
        let result = EmailAnalysisContract.deterministicSummary(
            subject: "Calendar invitation",
            body: "Alex shared the “Engineering” calendar and invited you. Accept the invitation to participate."
        )

        #expect(result.summary.contains("Engineering"))
        #expect(result.actionItems.isEmpty)
    }

    @Test("Current actions override every legacy Boolean recommendation", arguments: [false, true])
    func testActionItemsAreCanonical(legacyCandidate: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let email = EmailMessage(id: "actions", subject: "Please do something", body: "The report is available.")
        email.bodyContentVersion = 1
        email.analysisTodoCandidate = legacyCandidate
        context.insert(email)
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                EmailSummaryResult(summary: "An imperative-sounding summary", keyPoints: ["Check the report"], actionItems: [])
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        try await service.analyze(email, context: context)
        #expect(EmailAnalysisContract.currentActionItems(for: email).isEmpty)
        #expect(EmailAnalysisContract.todoCandidate(for: email) == false)
        email.analysisActionItems = [" Reply exactly. ", "", "Reply exactly.", "Check access if needed"]
        #expect(EmailAnalysisContract.currentActionItems(for: email) == ["Reply exactly.", "Check access if needed"])
        #expect(EmailAnalysisContract.todoCandidate(for: email) == true)
    }

    @Test("Old analysis contracts and changed source bodies cannot suggest stale actions")
    func testStaleActionsCannotPropose() {
        let email = EmailMessage(id: "stale", subject: "Request", body: "Please reply.")
        email.bodyContentVersion = 1
        email.analysisState = .analyzed
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body)
        email.analysisActionItems = ["Reply"]
        #expect(EmailAnalysisContract.currentActionItems(for: email) == ["Reply"])
        email.analysisVersion -= 1
        #expect(EmailAnalysisContract.currentActionItems(for: email).isEmpty)
        #expect(EmailAnalysisContract.todoCandidate(for: email) == nil)
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        email.body += "\nThe request is withdrawn."
        #expect(EmailAnalysisContract.currentActionItems(for: email).isEmpty)
    }

    @Test("The structured provider receives obligations after old truncation boundaries")
    func testCompleteSourceAnalysis() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let body = String(repeating: "Status details.\n", count: 500)
            + "--\nPlease check the token settings.\n> Prior token details.\nRenew it if this integration is still used."
        let email = EmailMessage(id: "late", subject: "Token expired", body: body)
        email.bodyContentVersion = 1
        context.insert(email)
        let actions = ["Check the token settings.", "Renew it if this integration is still used."]
        var calls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, source, _ in
                calls += 1
                #expect(source == body)
                return EmailSummaryResult(summary: "The token expired.", keyPoints: ["An integration is affected."], actionItems: actions)
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        try await service.analyze(email, context: context)
        try await service.analyze(email, context: context)
        #expect(calls == 1)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(EmailAnalysisContract.currentActionItems(for: stored) == actions)
    }

    @Test("Snippets and unverified legacy body caches are not model source", arguments: [false, true])
    func testNoPreviewAnalysis(nonemptyLegacyBody: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let email = EmailMessage(id: "no-body", subject: "Please reply", snippet: "Please reply immediately.",
                                 body: nonemptyLegacyBody ? "An old partial cache" : "")
        context.insert(email)
        var calls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                calls += 1
                return EmailSummaryResult(summary: "not reached", keyPoints: [], actionItems: ["not reached"])
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true }
        )
        try await service.analyze(email, context: context)
        #expect(calls == 0)
        #expect(email.analysisState == .failed)
        #expect(EmailAnalysisContract.todoCandidate(for: email) == nil)
    }

    @Test("Remote structured decoding preserves every action and explicit informational emptiness",
          arguments: [[], ["Check access"], (1...12).map { "Process item \($0)" }])
    func testRemoteStructuredActions(actions: [String]) throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "summary": "A factual summary", "key_points": ["A fact"], "action_items": actions
        ])
        let result = try OpenAIAnalysisService.decodeEmail(String(decoding: json, as: UTF8.self), modelID: "test")
        #expect(result.summary == "A factual summary")
        #expect(result.keyPoints == ["A fact"])
        #expect(result.actionItems == actions)
    }

    @Test("A missing or malformed remote action field is invalid, not informational",
          arguments: [
            #"{"summary":"Info","key_points":[]}"#,
            #"{"summary":"Info","key_points":[],"action_items":"Reply"}"#,
            #"{"summary":"Info","key_points":[],"action_items":[1]}"#,
            #"{"summary":"Info","action_items":[]}"#
          ])
    func testMalformedRemoteActions(response: String) {
        #expect(throws: (any Error).self) {
            try OpenAIAnalysisService.decodeEmail(response, modelID: "test")
        }
    }

    @Test("Bounded sections cover every source character without cutting off the tail")
    func testBodyChunkCoverage() {
        let body = String(repeating: "A factual paragraph with mixed 한국어 and العربية.\n", count: 200)
            + "Please complete the final required check."
        let chunks = EmailAnalysisContract.bodyChunks(body)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 1_800 })
        var reconstructed = chunks[0]
        for chunk in chunks.dropFirst() {
            #expect(reconstructed.suffix(200) == chunk.prefix(200))
            reconstructed += chunk.dropFirst(200)
        }
        #expect(reconstructed == body)
    }

}
