import CryptoKit
import Foundation
import SwiftData

struct EmailAnalysisOutcome<Value> {
    let value: Value
    let executionPath: AnalysisExecutionPath
}


enum EmailAnalysisContract {
    static let summaryContractVersion = 8

    /// Normalize presentation whitespace, not evidence. A signature separator or
    /// quoted section can precede a current obligation, so neither removes source.
    static func normalizedBody(_ body: String) -> String {
        unescapedWhitespace(in: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueItems(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedActionText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    static func actionIdentifier(_ action: String) -> String {
        SHA256.hash(data: Data(normalizedActionText(action).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func currentActionItems(for email: EmailMessage) -> [String] {
        guard isCurrentAnalysis(email), email.analysisFailureReasonRaw == nil else { return [] }
        return uniqueItems(email.analysisActionItems)
    }

    static func todoCandidate(for email: EmailMessage) -> Bool? {
        guard isCurrentAnalysis(email), email.analysisFailureReasonRaw == nil else { return nil }
        return !currentActionItems(for: email).isEmpty
    }

    /// Bounded model contexts overlap at boundaries, but never drop a source
    /// section. Prefer paragraph/line boundaries so quoted context stays visible.
    static func bodyChunks(_ body: String, characterLimit: Int = 1_800, overlap: Int = 200) -> [String] {
        precondition(characterLimit > overlap && overlap >= 0)
        var chunks: [String] = []
        var start = body.startIndex
        while start < body.endIndex {
            var end = body.index(start, offsetBy: characterLimit, limitedBy: body.endIndex) ?? body.endIndex
            if end < body.endIndex {
                let lower = body.index(start, offsetBy: max(overlap + 1, characterLimit / 2))
                if let boundary = body[lower..<end].lastIndex(of: "\n") {
                    end = body.index(after: boundary)
                }
            }
            chunks.append(String(body[start..<end]))
            guard end < body.endIndex else { break }
            start = body.index(end, offsetBy: -overlap, limitedBy: start) ?? end
        }
        return chunks
    }

    static func fingerprint(subject: String, body: String) -> String {
        // Hash complete evidence, not a model context window or presentation summary.
        // The version invalidates legacy independent Boolean recommendations.
        return SHA256.hash(
            data: Data("\(summaryContractVersion)\u{0}\(subject)\u{0}\(body)".utf8)
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
        // Contract 8 only analyzes complete bodies. Its current version and exact
        // source fingerprint also attest a synced result without a local fetch.
        !normalizedBody(body).isEmpty && email.analysisState == .analyzed
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
        email.analysisTodoCandidate = nil
        email.analysisTodoCandidateFingerprint = ""
    }

    static func deterministicSummary(subject: String, body: String, language: AppLanguage = .current) -> EmailSummaryResult {
        let sentences = informativeSentences(from: normalizedBody(body))
        guard !sentences.isEmpty else {
            return EmailSummaryResult(
                summary: normalizedBody(body),
                keyPoints: [],
                actionItems: []
            )
        }

        if let invitation = calendarInvitationSummary(subject: subject, sentences: sentences, language: language) {
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
        sentences: [String],
        language: AppLanguage
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
        return EmailSummaryResult(
            summary: requiresAcceptance
                ? String(format: AppLanguage.localized("mail.invitation.acceptSummary", defaultValue: "You were invited to share the %@ calendar. Accept the invitation to participate.", language: language), locale: language.locale, String(calendarName))
                : String(format: AppLanguage.localized("mail.invitation.summary", defaultValue: "You were invited to share the %@ calendar.", language: language), locale: language.locale, String(calendarName)),
            keyPoints: requiresAcceptance
                ? [AppLanguage.localized("mail.invitation.acceptKeyPoint", defaultValue: "Accepting the invitation lets you participate in the calendar.", language: language)]
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
    typealias FoundationModelsSummaryProvider = @MainActor (
        String,
        String,
        String,
        AppLanguage
    ) async throws -> EmailSummaryResult
    typealias FoundationModelsEnabledProvider = @MainActor () -> Bool
    typealias FoundationModelsAvailabilityProvider = @MainActor () -> Bool

    private let foundationModelsSummaryProvider: FoundationModelsSummaryProvider
    private let foundationModelsEnabledProvider: FoundationModelsEnabledProvider
    private let foundationModelsAvailabilityProvider: FoundationModelsAvailabilityProvider

    init(
        foundationModelsSummaryProvider: FoundationModelsSummaryProvider? = nil,
        foundationModelsEnabledProvider: @escaping FoundationModelsEnabledProvider = { BetaFeaturePolicy().authorizes(.foundationModels, for: .emailAnalysis) },
        foundationModelsAvailabilityProvider: FoundationModelsAvailabilityProvider? = nil
    ) {
        self.foundationModelsSummaryProvider = foundationModelsSummaryProvider ?? Self.summarizeWithFoundationModels
        self.foundationModelsEnabledProvider = foundationModelsEnabledProvider
        self.foundationModelsAvailabilityProvider = foundationModelsAvailabilityProvider ?? Self.foundationModelsAvailable
    }

    func needsAnalysis(_ email: EmailMessage) -> Bool {
        !EmailAnalysisContract.isCurrentAnalysis(email) || shouldRetryRuleFallback(email)
    }

    /// A real availability/opt-in transition may retry immediately; an unchanged
    /// retryable fallback must not invoke the same provider on every mailbox tick.
    var retryEligibilityVersion: Int {
        (foundationModelsEnabledProvider() ? 2 : 0) + (foundationModelsAvailabilityProvider() ? 1 : 0)
    }

    func analyze(
        _ email: EmailMessage,
        context: ModelContext,
        language: AppLanguage = .current,
        isAuthorized: () -> Bool = { true }
    ) async throws {
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
        let key = EmailMessageKey(email)
        let originalModelID = email.persistentModelID
        guard activeKeys.insert(key).inserted else { return }
        defer { activeKeys.remove(key) }

        let source = EmailAnalysisContract.normalizedBody(email.body)
        let fingerprint = EmailAnalysisContract.fingerprint(
            subject: email.subject,
            body: email.body
        )
        let shouldRetryRuleFallback = shouldRetryRuleFallback(email)
        let needsSummary = email.analysisState != .analyzed
            || email.analyzedBodyFingerprint != fingerprint
            || email.analysisVersion != EmailAnalysisContract.summaryContractVersion
            || shouldRetryRuleFallback
        guard needsSummary else { return }
        guard email.hasCompleteBody, !source.isEmpty else {
            if EmailAnalysisContract.isCurrentAnalysis(email) { return }
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
            // Selection and consent can change while the local model is suspended.
            guard isAuthorized() else { throw CancellationError() }
            guard let currentEmail = try resolvedEmail(matching: key, in: context) else {
                return
            }

            let result = outcome.value.normalized
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
            currentEmail.analysisTodoCandidate = currentEmail.analysisFailureReasonRaw == nil ? !result.actionItems.isEmpty : nil
            currentEmail.analysisTodoCandidateFingerprint = currentEmail.analysisTodoCandidate == nil ? "" : fingerprint
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

    /// The same complete-body structured analysis used by opted-in ingestion.
    /// A disabled/unavailable provider yields factual rules with no invented tasks.
    func summarizeContent(
        subject: String,
        sender: String,
        body: String,
        allowFoundationModels: Bool,
        language: AppLanguage = .current
    ) async throws -> EmailSummaryResult {
        let source = EmailAnalysisContract.normalizedBody(body)
        guard !source.isEmpty else {
            return EmailSummaryResult(summary: "", keyPoints: [], actionItems: [])
        }
        guard allowFoundationModels else {
            return EmailAnalysisContract.deterministicSummary(subject: subject, body: source, language: language)
        }
        return try await summarize(
            subject: subject, sender: sender, body: source, language: language
        ).value.normalized
    }
    private func summarize(
        subject: String,
        sender: String,
        body: String,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailSummaryResult> {
        let fallback: (RuleFallbackReason) -> EmailAnalysisOutcome<EmailSummaryResult> = { reason in
            EmailAnalysisOutcome(
                value: EmailAnalysisContract.deterministicSummary(subject: subject, body: body, language: language),
                executionPath: .rules(reason)
            )
        }
        guard foundationModelsEnabledProvider() else { return fallback(.providerDisabled) }
        guard foundationModelsAvailabilityProvider() else { return fallback(.unavailable) }
        do {
            return EmailAnalysisOutcome(
                value: try await foundationModelsSummaryProvider(subject, sender, body, language),
                executionPath: .beta(.foundationModels)
            )
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
        case .noProviderOptIn, .noEligibleProvider, .providerDisabled, .unavailable, .providerNotApplicable,
             .modelNotLoaded, .credentialMissing, .consentMissing:
            break
        case .invalidResponse, .providerExecutionFailed:
            return false
        }
        return foundationModelsEnabledProvider() && foundationModelsAvailabilityProvider()
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
        guard !email.hasCompleteBody || currentFingerprint != expectedFingerprint else { return false }
        if !EmailAnalysisContract.isCurrentAnalysis(email) {
            EmailAnalysisContract.resetAnalysis(email)
            _ = save(context)
        }
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

}

struct EmailSummaryResult: Sendable {
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]

    var normalized: EmailSummaryResult {
        EmailSummaryResult(
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: EmailAnalysisContract.uniqueItems(keyPoints),
            actionItems: EmailAnalysisContract.uniqueItems(actionItems)
        )
    }
}
