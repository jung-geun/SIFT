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
    var candidate: EmailCandidateOutcome?

    init(enabled: Bool, available: Bool = false, candidate: EmailCandidateOutcome? = nil) {
        self.enabled = enabled
        self.available = available
        self.candidate = candidate
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
    @Test("Real AFM opt-in ignores Laya and OpenAI task selections", arguments: [PersonaAIProvider.laya, .openAI])
    func testRealAFMGate(selectedProvider: PersonaAIProvider) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let defaults = UserDefaults.standard
            let keys = [SettingsStore.betaFoundationModelsEnabledKey, SettingsStore.betaLayaEnabledKey, SettingsStore.betaOpenAIEnabledKey, SettingsStore.betaSelectedProviderKey, "pieroot.todo.providerEmailAnalysisEnabled"]
            let previous = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, previous) {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: true)
            SettingsStore.shared.setBetaProvider(.laya, enabled: true)
            SettingsStore.shared.setBetaProvider(.openAI, enabled: true)
            defaults.set(selectedProvider.rawValue, forKey: SettingsStore.betaSelectedProviderKey)
            defaults.set(true, forKey: "pieroot.todo.providerEmailAnalysisEnabled")
            let schema = Schema([EmailMessage.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            let email = EmailMessage(id: "real-gate", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "real-gate", isInInbox: true)
            context.insert(email)
            var calls = 0
            let service = EmailMessageAnalysisService(
                foundationModelsSummaryProvider: { _, _, _, _ in
                    calls += 1
                    return EmailSummaryResult(summary: "Apple summary", keyPoints: [], actionItems: [])
                },
                foundationModelsAvailabilityProvider: { true },
                todoCandidateProvider: { _, _, _ in nil }
            )
            try await service.analyze(email, context: context)
            #expect(email.analysisSummary == "Apple summary")
            #expect(email.analysisFailureReasonRaw == nil)
            #expect(calls == 1)
            SettingsStore.shared.setBetaProvider(.foundationModels, enabled: false)
            email.body = "Please review the updated plan by Monday."
            try await service.analyze(email, context: context)
            #expect(email.analysisSummary == EmailAnalysisContract.deterministicSummary(subject: email.subject, body: email.body).summary)
            #expect(email.analysisFailureReasonRaw == RuleFallbackReason.providerDisabled.rawValue)
            #expect(calls == 1)
        }
    }

    @Test("Cached disabled and unavailable summaries upgrade when AFM becomes eligible", arguments: [false, true])
    func testIndependentAFMGates(initiallyEnabled: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "gates", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "gates", isInInbox: true)
        context.insert(email)
        let state = EmailModelGateState(enabled: initiallyEnabled)
        var calls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                calls += 1
                return EmailSummaryResult(summary: "Apple summary", keyPoints: ["Friday"], actionItems: ["Review plan"])
            },
            foundationModelsEnabledProvider: { state.enabled },
            foundationModelsAvailabilityProvider: { state.available },
            todoCandidateProvider: { _, _, _ in nil }
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

    @Test("Laya classifies cached summaries without rerunning AFM")
    func testCachedSummaryClassification() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "decision", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "decision", isInInbox: true)
        context.insert(email)
        var summaries = 0
        var decisions = 0
        let state = EmailModelGateState(enabled: true, available: true)
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                summaries += 1
                return EmailSummaryResult(summary: "Apple summary", keyPoints: [], actionItems: [])
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in
                decisions += 1
                return state.candidate
            }
        )
        try await service.analyze(email, context: context)
        #expect(email.analysisTodoCandidate == nil)
        #expect(email.analysisState == .analyzed)
        state.candidate = .notCandidate
        try await service.analyze(email, context: context)
        #expect(email.analysisTodoCandidate == false)
        #expect(email.analysisTodoCandidateFingerprint == email.analyzedBodyFingerprint)
        #expect(email.analysisSummary == "Apple summary")
        #expect(summaries == 1)
        #expect(decisions == 2)
        try await service.analyze(email, context: context)
        #expect(decisions == 2)
    }
    @Test("Uncertain and unavailable decisions persist nil without changing the summary baseline", arguments: [false, true])
    func testUnresolvedDecisionPersistence(uncertain: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "unresolved", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "unresolved", isInInbox: true)
        context.insert(email)
        let state = EmailModelGateState(enabled: true, candidate: uncertain ? .uncertain : nil)
        var summaryCalls = 0
        var decisionCalls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                summaryCalls += 1
                return EmailSummaryResult(summary: "must not run", keyPoints: [], actionItems: [])
            },
            foundationModelsEnabledProvider: { state.enabled },
            foundationModelsAvailabilityProvider: { state.available },
            todoCandidateProvider: { _, _, _ in
                decisionCalls += 1
                return state.candidate
            }
        )
        let baseline = EmailAnalysisContract.deterministicSummary(subject: email.subject, body: email.body)
        try await service.analyze(email, context: context)
        // A separate context proves the nil is stored, not just displayed on the live row.
        let persistedContext = ModelContext(container)
        let persisted = try #require(try persistedContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(persisted.analysisTodoCandidate == nil)
        #expect(persisted.analysisTodoCandidate != false)
        #expect(persisted.analysisTodoCandidateFingerprint.isEmpty)
        #expect(persisted.analysisState == .analyzed)
        #expect(persisted.analysisSummary == baseline.summary)
        #expect(persisted.analysisKeyPoints == baseline.keyPoints)
        #expect(persisted.analysisActionItems == baseline.actionItems)
        #expect(persisted.analysisFailureReasonRaw == RuleFallbackReason.unavailable.rawValue)
        #expect(persisted.analysisError.isEmpty)
        #expect(summaryCalls == 0)
        #expect(!context.hasChanges)

        // Neither absence nor uncertainty is cached as a definite negative.
        state.candidate = .candidate
        try await service.analyze(email, context: context)
        let resolvedContext = ModelContext(container)
        let resolved = try #require(try resolvedContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(resolved.analysisTodoCandidate == true)
        #expect(resolved.analysisTodoCandidateFingerprint == email.analyzedBodyFingerprint)
        #expect(resolved.analysisSummary == baseline.summary)
        #expect(resolved.analysisFailureReasonRaw == RuleFallbackReason.unavailable.rawValue)
        #expect(decisionCalls == 2)
        #expect(summaryCalls == 0)
    }

    @Test("Native classification receives original late and quoted text for new and cached summaries")
    func testClassificationPreservesOriginalBody() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let body = "<p>Project update.</p>\\n"
            + String(repeating: "Status details.\n", count: 1_000)
            + "-- Forwarded conversation\nPlease approve the revised plan by Friday.\n> Please send the signed agreement.\n"
        let normalized = EmailAnalysisContract.normalizedBody(body)
        #expect(!normalized.contains("Please approve"))
        #expect(!normalized.contains("Please send"))
        let email = EmailMessage(id: "original-text", subject: "Review", from: "alex@example.com", body: body, provider: .gmail, rawMessageID: "original-text", isInInbox: true)
        context.insert(email)
        var summaryCalls = 0
        var decisionBodies: [String] = []
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, source, _ in
                summaryCalls += 1
                #expect(source == normalized)
                return EmailSummaryResult(summary: "Apple summary", keyPoints: [], actionItems: [])
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { subject, sender, source in
                #expect(subject == email.subject)
                #expect(sender == email.from)
                decisionBodies.append(source)
                return .uncertain
            }
        )
        try await service.analyze(email, context: context)
        try await service.analyze(email, context: context)
        #expect(decisionBodies == [body, body])
        #expect(summaryCalls == 1)
        #expect(email.analysisSummary == "Apple summary")
        #expect(email.analysisTodoCandidate == nil)
        #expect(email.analysisTodoCandidateFingerprint.isEmpty)
    }

    @Test("Quoted-only changes invalidate a cached native recommendation")
    func testQuotedBodyChangeInvalidatesCachedDecision() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let body = "Project update.\n> Please approve the plan."
        let updatedBody = "Project update.\n> No approval is needed."
        #expect(EmailAnalysisContract.normalizedBody(body) == EmailAnalysisContract.normalizedBody(updatedBody))
        let email = EmailMessage(id: "quoted-cache", subject: "Review", body: body, provider: .gmail, rawMessageID: "quoted-cache", isInInbox: true)
        context.insert(email)
        let state = EmailModelGateState(enabled: false, candidate: .candidate)
        var decisionBodies: [String] = []
        let service = EmailMessageAnalysisService(
            foundationModelsEnabledProvider: { false },
            todoCandidateProvider: { _, _, source in
                decisionBodies.append(source)
                return state.candidate
            }
        )
        try await service.analyze(email, context: context)
        let originalFingerprint = email.analysisTodoCandidateFingerprint
        #expect(email.analysisTodoCandidate == true)
        email.body = updatedBody
        state.candidate = .notCandidate
        try context.save()
        try await service.analyze(email, context: context)
        let persistedContext = ModelContext(container)
        let persisted = try #require(try persistedContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(decisionBodies == [body, updatedBody])
        #expect(persisted.analysisTodoCandidate == false)
        #expect(persisted.analysisTodoCandidateFingerprint != originalFingerprint)
        #expect(persisted.analysisTodoCandidateFingerprint == EmailAnalysisContract.fingerprint(subject: email.subject, body: updatedBody))
        #expect(persisted.analysisSummary == EmailAnalysisContract.deterministicSummary(subject: email.subject, body: updatedBody).summary)
    }

    @Test("Legacy Boolean recommendations are reclassified under the native predicate contract", arguments: [false, true])
    func testLegacyCandidateCacheIsInvalidated(legacyCandidate: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "legacy-decision", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "legacy-decision", isInInbox: true)
        context.insert(email)
        let legacyFingerprint = SHA256.hash(data: Data("\(email.subject)\u{0}\(EmailAnalysisContract.normalizedBody(email.body))".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        email.analysisState = .analyzed
        email.analysisSummary = "Legacy summary"
        email.analyzedBodyFingerprint = legacyFingerprint
        email.analysisTodoCandidate = legacyCandidate
        email.analysisTodoCandidateFingerprint = legacyFingerprint
        email.analysisVersion = 6
        try context.save()
        var decisions = 0
        let service = EmailMessageAnalysisService(
            foundationModelsEnabledProvider: { false },
            todoCandidateProvider: { _, _, _ in
                decisions += 1
                return .uncertain
            }
        )
        try await service.analyze(email, context: context)
        let persistedContext = ModelContext(container)
        let persisted = try #require(try persistedContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(decisions == 1)
        #expect(persisted.analysisTodoCandidate == nil)
        #expect(persisted.analysisTodoCandidateFingerprint.isEmpty)
        #expect(persisted.analyzedBodyFingerprint != legacyFingerprint)
        #expect(persisted.analysisVersion == EmailAnalysisContract.summaryContractVersion)
    }

    @Test("AFM execution errors retain deterministic analysis and reason")
    func testAFMErrorFallsBack() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "error", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "error", isInInbox: true)
        context.insert(email)
        var summaryCalls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: { _, _, _, _ in
                summaryCalls += 1
                throw NSError(domain: "test", code: 1)
            },
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in .candidate }
        )
        try await service.analyze(email, context: context)
        #expect(email.analysisState == .analyzed)
        #expect(email.analysisSummary == EmailAnalysisContract.deterministicSummary(subject: email.subject, body: email.body).summary)
        #expect(email.analysisFailureReasonRaw == RuleFallbackReason.providerExecutionFailed.rawValue)
        #expect(email.analysisTodoCandidate == true)
        try await service.analyze(email, context: context)
        #expect(summaryCalls == 1)
        #expect(email.analysisFailureReasonRaw == RuleFallbackReason.providerExecutionFailed.rawValue)
    }
    @Test("Cancelling inbox classification keeps a completed summary")
    func testDecisionCancellationKeepsSummary() async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "decision-cancel", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "decision-cancel", isInInbox: true)
        context.insert(email)
        let suspended = CancellableEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsEnabledProvider: { false },
            todoCandidateProvider: { subject, sender, body in
                _ = try await suspended.summarize(subject: subject, sender: sender, body: body, language: .english)
                return .candidate
            }
        )
        let task = Task { () -> Error? in
            do { try await service.analyze(email, context: context); return nil }
            catch { return error }
        }
        while !suspended.started { await Task.yield() }
        task.cancel()
        #expect(await task.value is CancellationError)
        #expect(email.analysisState == .analyzed)
        #expect(email.analysisSummary == EmailAnalysisContract.deterministicSummary(subject: email.subject, body: email.body).summary)
        #expect(email.analysisTodoCandidate == nil)
        #expect(email.analysisTodoCandidateFingerprint.isEmpty)
        #expect(!context.hasChanges)
    }


    @Test("A decision for a changed source is discarded with its old summary", arguments: [false, true])
    func testDecisionSourceRace(rawOnlyMutation: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "decision-race", subject: "Review", body: "Please review the plan by Friday.\n> Please send the signed agreement.", provider: .gmail, rawMessageID: "decision-race", isInInbox: true)
        context.insert(email)
        let suspended = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsEnabledProvider: { false },
            todoCandidateProvider: { subject, sender, body in
                _ = try await suspended.summarize(subject: subject, sender: sender, body: body, language: .english)
                return .candidate
            }
        )
        let task = Task { try await service.analyze(email, context: context) }
        await suspended.waitUntilSuspended()
        #expect(email.analysisState == .analyzed)
        let originalBody = email.body
        let originalFingerprint = email.analyzedBodyFingerprint
        email.body = rawOnlyMutation
            ? "Please review the plan by Friday.\n> Please do not send the signed agreement."
            : "This is a different message."
        #expect(EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body) != originalFingerprint)
        #expect((EmailAnalysisContract.normalizedBody(email.body) == EmailAnalysisContract.normalizedBody(originalBody)) == rawOnlyMutation)
        try context.save()
        suspended.resume(with: EmailSummaryResult(summary: "ignored", keyPoints: [], actionItems: []))
        try await task.value
        #expect(email.analysisTodoCandidate == nil)
        #expect(email.analysisTodoCandidateFingerprint.isEmpty)
        #expect(email.analysisState == .unanalyzed)
        #expect(email.analysisSummary.isEmpty)
    }

    @Test("Classification checks cancellation before and after suspension without persisting a negative", arguments: [false, true])
    func testDecisionCancellationAroundSuspension(cancelBeforeStart: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "cached-cancel", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "cached-cancel", isInInbox: true)
        context.insert(email)
        email.analysisState = .analyzed
        email.analysisSummary = "Existing summary"
        email.analyzedBodyFingerprint = EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body)
        email.analysisVersion = EmailAnalysisContract.summaryContractVersion
        try context.save()
        let suspended = SuspendedEmailSummaryProvider()
        var decisionCalls = 0
        let service = EmailMessageAnalysisService(
            foundationModelsEnabledProvider: { false },
            todoCandidateProvider: { subject, sender, body in
                decisionCalls += 1
                // This provider ignores cancellation; the service must recheck on return.
                _ = try await suspended.summarize(subject: subject, sender: sender, body: body, language: .english)
                return .notCandidate
            }
        )
        let task = Task { () -> Error? in
            if cancelBeforeStart {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            do { try await service.analyze(email, context: context); return nil }
            catch { return error }
        }
        if !cancelBeforeStart {
            await suspended.waitUntilSuspended()
            task.cancel()
            suspended.resume(with: EmailSummaryResult(summary: "ignored", keyPoints: [], actionItems: []))
        }
        #expect(await task.value is CancellationError)
        #expect(decisionCalls == (cancelBeforeStart ? 0 : 1))
        #expect(email.analysisState == .analyzed)
        #expect(email.analysisSummary == "Existing summary")
        #expect(email.analysisError.isEmpty)
        #expect(email.analysisTodoCandidate == nil)
        #expect(email.analysisTodoCandidateFingerprint.isEmpty)
        #expect(!context.hasChanges)
        let persistedContext = ModelContext(container)
        let persisted = try #require(try persistedContext.fetch(FetchDescriptor<EmailMessage>()).first)
        #expect(persisted.analysisTodoCandidate == nil)
        #expect(persisted.analysisSummary == "Existing summary")
    }

    @Test("Classification does not access or recreate a deleted source row", arguments: [false, true])
    func testDecisionAfterSourceDeletion(cancelled: Bool) async throws {
        let schema = Schema([EmailMessage.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let email = EmailMessage(id: "decision-deleted", subject: "Review", body: "Please review the plan by Friday.", provider: .gmail, rawMessageID: "decision-deleted", isInInbox: true)
        context.insert(email)
        let suspended = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsEnabledProvider: { false },
            todoCandidateProvider: { subject, sender, body in
                _ = try await suspended.summarize(subject: subject, sender: sender, body: body, language: .english)
                return .candidate
            }
        )
        let task = Task { () -> Error? in
            do { try await service.analyze(email, context: context); return nil }
            catch { return error }
        }
        await suspended.waitUntilSuspended()
        context.delete(email)
        try context.save()
        if cancelled { task.cancel() }
        suspended.resume(with: EmailSummaryResult(summary: "ignored", keyPoints: [], actionItems: []))
        let error = await task.value
        if cancelled { #expect(error is CancellationError) }
        else { #expect(error == nil) }
        let persistedContext = ModelContext(container)
        #expect(try persistedContext.fetch(FetchDescriptor<EmailMessage>()).isEmpty)
        #expect(!context.hasChanges)
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
        context.insert(email)
        try context.save()

        let provider = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: provider.summarize,
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in nil }
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
        context.insert(email)
        try context.save()

        let provider = CancellableEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: provider.summarize,
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in nil }
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
        context.insert(email)
        try context.save()

        let provider = SuspendedEmailSummaryProvider()
        let service = EmailMessageAnalysisService(
            foundationModelsSummaryProvider: provider.summarize,
            foundationModelsEnabledProvider: { true },
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in nil }
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
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in nil }
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
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in nil }
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
            foundationModelsAvailabilityProvider: { true },
            todoCandidateProvider: { _, _, _ in nil }
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

}
