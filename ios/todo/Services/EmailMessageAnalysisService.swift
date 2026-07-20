import CryptoKit
import Foundation
import SwiftData

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
private struct FMEmailSummaryOutput {
    @Guide(description: "Compress the email's main point into 1–3 concise bullets. Exclude greetings, signatures, quoted text, and CID markup.")
    var summary: String

    @Guide(description: "List 0–4 key facts, decisions, amounts, or deadlines. One fact per sentence.")
    var keyPoints: [String]

    @Guide(description: "List only 0–4 actions the recipient must actually take. Return an empty array when there are none. Do not infer.")
    var actionItems: [String]
}
#endif

enum EmailAnalysisContract {
    static let summaryContractVersion = 3

    static func normalizedBody(_ body: String) -> String {
        body
            .components(separatedBy: .newlines)
            .prefix { line in !line.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix(">") && !trimmed.localizedCaseInsensitiveContains("cid:")
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        email.analyzedBodyFingerprint = ""
        email.analyzedAt = nil
        email.analysisVersion = 0
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

    private let summaryProvider: SummaryProvider?

    private init() {
        summaryProvider = nil
    }

    init(summaryProvider: @escaping SummaryProvider) {
        self.summaryProvider = summaryProvider
    }

    func analyze(
        _ email: EmailMessage,
        context: ModelContext,
        language: AppLanguage = .current
    ) async {
        let key = EmailMessageKey(email)
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
        guard email.analysisState != .analyzed
            || email.analyzedBodyFingerprint != fingerprint
            || email.analysisVersion != EmailAnalysisContract.summaryContractVersion
        else { return }

        email.analysisState = .analyzing
        email.analysisError = ""
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
            let result = try await summarize(
                subject: email.subject,
                sender: email.from,
                body: source,
                language: language
            )
            guard !discardAnalysisIfSourceChanged(
                email,
                expectedFingerprint: fingerprint,
                context: context
            ) else {
                return
            }
            email.analysisSummary = result.summary
            email.analysisKeyPoints = result.keyPoints
            email.analysisActionItems = result.actionItems
            email.analysisDetail = ""
            email.analysisState = .analyzed
            email.analyzedBodyFingerprint = fingerprint
            email.analysisVersion = EmailAnalysisContract.summaryContractVersion
            email.analyzedAt = Date()
            guard save(context) else {
                persistFailure(
                    email,
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
        } catch {
            guard !discardAnalysisIfSourceChanged(
                email,
                expectedFingerprint: fingerprint,
                context: context
            ) else {
                return
            }
            persistFailure(email, context: context, message: error.localizedDescription)
        }
    }

    private func summarize(
        subject: String,
        sender: String,
        body: String,
        language: AppLanguage
    ) async throws -> EmailSummaryResult {
        if let summaryProvider {
            return try await summaryProvider(subject, sender, body)
        }
        #if canImport(FoundationModels)
        guard FoundationModelsAvailability.isAvailable, #available(iOS 26.0, *) else {
            throw SummaryError.unavailable
        }
        let instructions = AppLanguage.localized(
            "mail.analysis.instruction",
            defaultValue: language == .english
                ? "Summarize this email concisely. Do not repeat the source; output the key points, important facts, and actions the recipient must take. Write every natural-language field in English and do not translate the source content."
                : "당신은 이메일을 간결하게 정리합니다. 원문을 반복하지 말고 요점, 중요한 사실, 수신자가 해야 하는 일만 출력합니다. 자연어 필드는 모두 한국어로 작성하되 원문 내용은 번역하지 않습니다.",
            language: language,
            comment: "Email analysis model instruction"
        )
        let prompt = "발신자: \(sender)\n제목: \(subject)\n본문:\n\(String(body.prefix(8_000)))"
        LLMDebugLogger.request(
            provider: "AFM",
            operation: "summarizeEmailMessage",
            metadata: ["subject: \(subject)", "bodyChars: \(min(body.count, 8_000))"],
            systemPrompt: instructions,
            userPrompt: prompt
        )
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: FMEmailSummaryOutput.self)
        let output = response.content
        LLMDebugLogger.response(provider: "AFM", operation: "summarizeEmailMessage", text: "summary=\(output.summary)\nkeyPoints=\(output.keyPoints.joined(separator: " | "))\nactionItems=\(output.actionItems.joined(separator: " | "))")
        return EmailSummaryResult(
            summary: output.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: output.keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            actionItems: output.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
        #else
        throw SummaryError.unavailable
        #endif
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
