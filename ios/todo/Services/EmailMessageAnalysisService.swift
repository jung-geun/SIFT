import CryptoKit
import Foundation
import SwiftData


enum EmailAnalysisContract {
    static let summaryContractVersion = 6

    static func normalizedBody(_ body: String) -> String {
        unescapedWhitespace(in: body)
            .components(separatedBy: .newlines)
            .prefix { line in !line.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix(">") && !trimmed.localizedCaseInsensitiveContains("cid:")
            }
            .map {
                $0
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func fingerprint(subject: String, body: String) -> String {
        let normalizedBody = normalizedBody(body)
        return SHA256.hash(
            data: Data("\(subject)\u{0}\(normalizedBody)".utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }

    static func isCurrentAnalysis(_ email: EmailMessage) -> Bool {
        matchesAnalysis(
            email,
            subject: email.subject,
            body: email.body
        )
    }

    static func matchesAnalysis(
        _ email: EmailMessage,
        subject: String,
        body: String
    ) -> Bool {
        !normalizedBody(body).isEmpty
            && email.analysisState == .analyzed
            && email.analysisVersion == summaryContractVersion
            && email.analyzedBodyFingerprint == fingerprint(
                subject: subject,
                body: body
            )
    }

    static func resetAnalysis(_ email: EmailMessage) {
        email.analysisState = .unanalyzed
        email.analysisSummary = ""
        email.analysisDetail = ""
        email.analysisKeyPoints = []
        email.analysisActionItems = []
        email.analysisError = ""
        email.analysisFailureReasonRaw = nil
        email.analyzedBodyFingerprint = ""
        email.analyzedAt = nil
        email.analysisVersion = 0
    }

    static func deterministicSummary(subject: String, body: String) -> EmailSummaryResult {
        let sentences = informativeSentences(from: normalizedBody(body))
        guard !sentences.isEmpty else {
            return EmailSummaryResult(
                summary: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                keyPoints: [],
                actionItems: []
            )
        }

        if let invitation = calendarInvitationSummary(subject: subject, sentences: sentences) {
            return invitation
        }

        let summarySentences = Array(sentences.prefix(2))
        return EmailSummaryResult(
            summary: summarySentences.joined(separator: " "),
            keyPoints: Array(sentences.dropFirst(summarySentences.count).prefix(3)),
            actionItems: []
        )
    }

    private static func unescapedWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: #"\r\n"#, with: "\n")
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\r"#, with: "\n")
            .replacingOccurrences(of: #"\t"#, with: " ")
    }

    private static func calendarInvitationSummary(
        subject: String,
        sentences: [String]
    ) -> EmailSummaryResult? {
        let content = ([subject] + sentences).joined(separator: " ")
        let lowercased = content.lowercased()
        let isKorean = content.range(
            of: #"[ㄱ-ㅎㅏ-ㅣ가-힣]"#,
            options: .regularExpression
        ) != nil
        let hasCalendar = isKorean
            ? content.contains("캘린더")
            : lowercased.contains("calendar")
        let isInvitation = isKorean
            ? content.contains("공유") && content.contains("초대")
            : lowercased.contains("share") && lowercased.contains("invite")
        guard hasCalendar, isInvitation,
              let calendarName = calendarName(in: content, isKorean: isKorean)
        else {
            return nil
        }

        let requiresAcceptance = isKorean
            ? content.contains("수락")
            : lowercased.contains("accept")
        if isKorean {
            return EmailSummaryResult(
                summary: requiresAcceptance
                    ? "\(calendarName) 캘린더 공유 초대입니다. 참여하려면 초대를 수락하세요."
                    : "\(calendarName) 캘린더 공유 초대입니다.",
                keyPoints: requiresAcceptance
                    ? ["공유 초대를 수락하면 캘린더에 참여할 수 있습니다."]
                    : [],
                actionItems: []
            )
        }
        return EmailSummaryResult(
            summary: requiresAcceptance
                ? "You were invited to share the \(calendarName) calendar. Accept the invitation to participate."
                : "You were invited to share the \(calendarName) calendar.",
            keyPoints: requiresAcceptance
                ? ["Accepting the invitation lets you participate in the calendar."]
                : [],
            actionItems: []
        )
    }

    private static func calendarName(in content: String, isKorean: Bool) -> String? {
        let pattern = isKorean
            ? #"["'“]([^"'”]{1,120})["'”]\s*캘린더"#
            : #"["'“]([^"'”]{1,120})["'”]\s+calendar"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: content,
                  range: NSRange(content.startIndex..., in: content)
              ),
              let range = Range(match.range(at: 1), in: content)
        else {
            return nil
        }
        return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func informativeSentences(from body: String) -> [String] {
        let withoutLinks = body
            .replacingOccurrences(of: #"\[[^\]]{0,500}\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"https?://[^\s\])>]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map {
                $0
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "\n")

        let candidates = withoutLinks
            .components(separatedBy: CharacterSet(charactersIn: ".!?。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { candidate in
                let words = candidate.split(whereSeparator: \.isWhitespace)
                let containsCJK = candidate.range(
                    of: #"[ㄱ-ㅎㅏ-ㅣ가-힣一-龯ぁ-ゟ゠-ヿ]"#,
                    options: .regularExpression
                ) != nil
                return containsCJK
                    ? candidate.count >= 10
                    : candidate.count >= 24 && words.count >= 5
            }

        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted
        }
    }
}

@MainActor
final class EmailMessageAnalysisService {
    static let shared = EmailMessageAnalysisService()
    private var activeKeys = Set<EmailMessageKey>()
    typealias SummaryProvider = @MainActor (
        String,
        String,
        String
    ) async throws -> EmailSummaryResult
    typealias FoundationModelsSummaryProvider = @MainActor (
        String,
        String,
        String,
        AppLanguage
    ) async throws -> EmailSummaryResult
    typealias RoutingDecisionProvider = @Sendable () -> ProviderRoutingDecision
    typealias FoundationModelsAvailabilityProvider = @MainActor () -> Bool

    private let summaryProvider: SummaryProvider?
    private let foundationModelsSummaryProvider: FoundationModelsSummaryProvider
    private let routingDecisionProvider: RoutingDecisionProvider
    private let foundationModelsAvailabilityProvider: FoundationModelsAvailabilityProvider

    private init() {
        summaryProvider = nil
        foundationModelsSummaryProvider = Self.summarizeWithFoundationModels
        routingDecisionProvider = { BetaFeaturePolicy().routingDecision(for: .standardAnalysis) }
        foundationModelsAvailabilityProvider = Self.foundationModelsAvailable
    }

    init(summaryProvider: @escaping SummaryProvider) {
        self.summaryProvider = summaryProvider
        foundationModelsSummaryProvider = Self.summarizeWithFoundationModels
        routingDecisionProvider = { BetaFeaturePolicy().routingDecision(for: .standardAnalysis) }
        foundationModelsAvailabilityProvider = Self.foundationModelsAvailable
    }

    init(
        foundationModelsSummaryProvider: @escaping FoundationModelsSummaryProvider,
        routingDecisionProvider: @escaping RoutingDecisionProvider,
        foundationModelsAvailabilityProvider: @escaping FoundationModelsAvailabilityProvider = { true }
    ) {
        summaryProvider = nil
        self.foundationModelsSummaryProvider = foundationModelsSummaryProvider
        self.routingDecisionProvider = routingDecisionProvider
        self.foundationModelsAvailabilityProvider = foundationModelsAvailabilityProvider
    }

    func analyze(
        _ email: EmailMessage,
        context: ModelContext,
        language: AppLanguage = .current
    ) async throws {
        let key = EmailMessageKey(email)
        let originalModelID = email.persistentModelID
        guard activeKeys.insert(key).inserted else { return }
        defer { activeKeys.remove(key) }

        let source = EmailAnalysisContract.normalizedBody(email.body)
        let fingerprint = EmailAnalysisContract.fingerprint(
            subject: email.subject,
            body: email.body
        )
        guard !source.isEmpty else {
            persistFailure(
                email,
                context: context,
                message: AppLanguage.localized(
                    "mail.analysis.noBody",
                    defaultValue: language == .english
                        ? "The email body could not be loaded for analysis."
                        : "분석할 본문을 불러오지 못했습니다.",
                    language: language,
                    comment: "Email analysis missing body error"
                )
            )
            return
        }
        let shouldRetryRuleFallback = shouldRetryRuleFallback(email)
        guard email.analysisState != .analyzed
            || email.analyzedBodyFingerprint != fingerprint
            || email.analysisVersion != EmailAnalysisContract.summaryContractVersion
            || shouldRetryRuleFallback
        else { return }

        email.analysisState = .analyzing
        email.analysisError = ""
        email.analysisFailureReasonRaw = nil
        guard save(context) else {
            persistFailure(
                email,
                context: context,
                message: AppLanguage.localized(
                    "mail.analysis.saveStateFailed",
                    defaultValue: language == .english
                        ? "The email analysis state could not be saved."
                        : "분석 상태를 저장하지 못했습니다.",
                    language: language,
                    comment: "Email analysis persistence error"
                )
            )
            return
        }

        do {
            let outcome = try await summarize(
                subject: email.subject,
                sender: email.from,
                body: source,
                language: language
            )
            try Task.checkCancellation()
            guard let currentEmail = try resolvedEmail(matching: key, in: context) else {
                return
            }

            let result = outcome.value
            switch outcome.executionPath {
            case .rules(let reason):
                currentEmail.analysisFailureReasonRaw = reason.rawValue
            case .beta:
                currentEmail.analysisFailureReasonRaw = nil
            }
            guard !discardAnalysisIfSourceChanged(
                currentEmail,
                expectedFingerprint: fingerprint,
                context: context
            ) else {
                return
            }
            currentEmail.analysisSummary = result.summary
            currentEmail.analysisKeyPoints = result.keyPoints
            currentEmail.analysisActionItems = result.actionItems
            currentEmail.analysisDetail = ""
            currentEmail.analysisState = .analyzed
            currentEmail.analyzedBodyFingerprint = fingerprint
            currentEmail.analysisVersion = EmailAnalysisContract.summaryContractVersion
            currentEmail.analyzedAt = Date()
            guard save(context) else {
                persistFailure(
                    currentEmail,
                    context: context,
                    message: AppLanguage.localized(
                        "mail.analysis.saveResultFailed",
                        defaultValue: language == .english
                            ? "The email analysis result could not be saved."
                            : "분석 결과를 저장하지 못했습니다.",
                        language: language,
                        comment: "Email analysis persistence error"
                    )
                )
                return
            }
        } catch is CancellationError {
            if let currentEmail = try? resolvedEmail(matching: key, in: context),
               currentEmail.persistentModelID == originalModelID {
                currentEmail.analysisState = .unanalyzed
                currentEmail.analysisFailureReasonRaw = nil
                currentEmail.analysisError = ""
                _ = save(context)
            }
            throw CancellationError()
        } catch {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            guard let currentEmail = try? resolvedEmail(matching: key, in: context) else {
                return
            }
            guard !discardAnalysisIfSourceChanged(
                currentEmail,
                expectedFingerprint: fingerprint,
                context: context
            ) else {
                return
            }
            currentEmail.analysisFailureReasonRaw = ProviderErrorMapper.fallbackReason(for: error)?.rawValue
            persistFailure(currentEmail, context: context, message: error.localizedDescription)
        }
    }
    private func summarize(
        subject: String,
        sender: String,
        body: String,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailSummaryResult> {
        if let summaryProvider {
            return EmailAnalysisOutcome(
                value: try await summaryProvider(subject, sender, body),
                executionPath: .rules(.noProviderOptIn)
            )
        }
        let fallback: (RuleFallbackReason) -> EmailAnalysisOutcome<EmailSummaryResult> = { reason in
            EmailAnalysisOutcome(
                value: EmailAnalysisContract.deterministicSummary(subject: subject, body: body),
                executionPath: .rules(reason)
            )
        }
        let decision = routingDecisionProvider()
        guard case .providers(let providers) = decision, let provider = providers.first else {
            if case .rules(let reason) = decision { return fallback(reason) }
            return fallback(.noEligibleProvider)
        }
        let instructions = AppLanguage.localized(
            "mail.analysis.instruction",
            defaultValue: language == .english
                ? "Summarize this email concisely. Return JSON with summary, keyPoints, and actionItems."
                : "이메일을 간결하게 요약하세요. summary, keyPoints, actionItems 키를 가진 JSON으로 답하세요.",
            language: language,
            comment: "Email analysis model instruction"
        )
        let prompt = "발신자: \(sender)\n제목: \(subject)\n본문:\n\(String(body.prefix(8_000)))"
        do {
            switch provider {
            case .gemini:
                guard SettingsStore.shared.get("pieroot.todo.providerEmailAnalysisEnabled", defaultValue: false) else {
                    return fallback(.consentMissing)
                }
                return EmailAnalysisOutcome(
                    value: try await GeminiProviderService().summarizeEmail(
                        subject: subject,
                        body: body,
                        language: language
                    ),
                    executionPath: .beta(.gemini)
                )
            case .foundationModels:
                return EmailAnalysisOutcome(
                    value: try await foundationModelsSummaryProvider(subject, sender, body, language),
                    executionPath: .beta(.foundationModels)
                )
            case .onDevice:
                guard OnDeviceLLMService.shared.isModelLoaded else {
                    return fallback(.modelNotLoaded)
                }
                let raw = try await OnDeviceLLMService.shared.generate(
                    systemPrompt: instructions,
                    userPrompt: prompt,
                    maxTokens: 900,
                    use: .standardAnalysis
                )
                guard let result = Self.parseSummary(raw) else {
                    return fallback(.invalidResponse)
                }
                return EmailAnalysisOutcome(value: result, executionPath: .beta(.onDevice))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback(ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed)
        }
    }




    private func shouldRetryRuleFallback(_ email: EmailMessage) -> Bool {
        guard let rawReason = email.analysisFailureReasonRaw,
              let reason = RuleFallbackReason(rawValue: rawReason)
        else {
            return false
        }
        switch reason {
        case .noProviderOptIn, .noEligibleProvider, .providerDisabled, .unavailable:
            break
        case .modelNotLoaded, .credentialMissing, .consentMissing, .invalidResponse, .providerExecutionFailed:
            return false
        }
        guard case .providers(let providers) = routingDecisionProvider(),
              providers == [.foundationModels]
        else {
            return false
        }
        return foundationModelsAvailabilityProvider()
    }

    private static func foundationModelsAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelsAvailability.isAvailable
        }
        #endif
        return false
    }

    private static func summarizeWithFoundationModels(
        subject: String,
        sender: String,
        body: String,
        language: AppLanguage
    ) async throws -> EmailSummaryResult {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .foundationModels,
                reason: RuleFallbackReason.unavailable.rawValue
            )
        }
        return try await FoundationModelsService().summarizeEmail(
            subject: subject,
            sender: sender,
            body: body,
            language: language
        )
        #else
        throw IntelligenceRoutingError.backendUnavailable(
            provider: .foundationModels,
            reason: RuleFallbackReason.unavailable.rawValue
        )
        #endif
    }

    private static func parseSummary(_ raw: String) -> EmailSummaryResult? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.range(of: "{"), let last = trimmed.range(of: "}", options: .backwards) {
            trimmed = String(trimmed[first.lowerBound..<last.upperBound])
        }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let summary = (json["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPoints = (json["keyPoints"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let actionItems = (json["actionItems"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty || !keyPoints.isEmpty || !actionItems.isEmpty else { return nil }
        return EmailSummaryResult(summary: summary, keyPoints: keyPoints, actionItems: actionItems)
    }

    private func resolvedEmail(
        matching key: EmailMessageKey,
        in context: ModelContext
    ) throws -> EmailMessage? {
        let providerRawValue = key.providerRawValue
        let sourceAccountNamespace = key.sourceAccountNamespace
        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
                    && email.sourceAccountNamespace == sourceAccountNamespace
            },
            sortBy: [SortDescriptor(\EmailMessage.receivedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
            .first { EmailMessageKey($0) == key }
    }

    private func discardAnalysisIfSourceChanged(
        _ email: EmailMessage,
        expectedFingerprint: String,
        context: ModelContext
    ) -> Bool {
        let currentFingerprint = EmailAnalysisContract.fingerprint(
            subject: email.subject,
            body: email.body
        )
        guard currentFingerprint != expectedFingerprint else { return false }
        EmailAnalysisContract.resetAnalysis(email)
        _ = save(context)
        return true
    }

    private func persistFailure(_ email: EmailMessage, context: ModelContext, message: String) {
        email.analysisState = .failed
        email.analysisError = message
        _ = save(context)
    }

    private func save(_ context: ModelContext) -> Bool {
        do { try context.save(); return true }
        catch { return false }
    }


    private enum SummaryError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            AppLanguage.localized(
                "error.mail.analysisUnavailable",
                defaultValue: AppLanguage.current == .english
                    ? "Apple Intelligence is unavailable, so the email summary could not be generated."
                    : "Apple Intelligence를 사용할 수 없어 이메일 요약을 생성하지 못했습니다.",
                language: .current,
                comment: "Email analysis unavailable error"
            )
        }
    }
}

struct EmailSummaryResult: Sendable {
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
}
