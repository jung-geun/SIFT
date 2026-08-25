import Foundation

// MARK: - Email Analysis Engine Protocol

struct EmailAnalysisOutcome<Value> {
    let value: Value
    let executionPath: AnalysisExecutionPath
}

/// 이메일 제목·본문·발신자를 받아 마감일 추출 결과를 반환하는 엔진 프로토콜.
///
/// 포그라운드: 사용자가 선택한 AI provider(AFΜ/Gemini/온디바이스)로 분석.
/// 백그라운드: OnDeviceDetectorEngine (NSDataDetector, 결정론적).
///
/// ⚠️ 프라이버시 불변식 — 외부 provider(Gemini)는 사용자가 해당 provider를 선택한 경우에만 사용한다.
protocol EmailAnalysisEngine {
    /// GmailMessage를 분석해 마감일을 추출한다.
    /// - Parameters:
    ///   - msg: 분석할 Gmail 메시지 (subject + body + from 헤더 포함)
    ///   - now: 기준 시각 (테스트·재현 가능성을 위해 주입)
    /// - Returns: 마감일이 감지되면 EmailExtraction, 없으면 nil
    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?>
}

// MARK: - On-Device Detector Engine (deterministic fallback)

/// NSDataDetector 기반 온디바이스 분석 엔진.
/// EmailContentAnalyzer를 래핑한다. 네트워크·AFM 없이 완전 로컬.
struct OnDeviceDetectorEngine: EmailAnalysisEngine {
    private let analyzer = EmailContentAnalyzer()
    private let fallbackReason: RuleFallbackReason

    init(fallbackReason: RuleFallbackReason = .noProviderOptIn) {
        self.fallbackReason = fallbackReason
    }

    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?> {
        EmailAnalysisOutcome(
            value: analyzer.analyze(msg, now: now, language: language),
            executionPath: .rules(fallbackReason)
        )
    }
}

// MARK: - Foundation Models Email Engine

struct FoundationModelsEmailEngine: EmailAnalysisEngine {
    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
            do {
                let value = try await FoundationModelsService().analyzeEmail(
                    msg,
                    now: now,
                    language: language
                )
                return EmailAnalysisOutcome(value: value, executionPath: .beta(.foundationModels))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return EmailAnalysisOutcome(
                    value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
                    executionPath: .rules(ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed)
                )
            }
        }
        #endif
        return EmailAnalysisOutcome(
            value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
            executionPath: .rules(.unavailable)
        )
    }
}

// MARK: - Local LLM Email Engine
struct LocalLLMEmailAnalysisEngine: EmailAnalysisEngine {
    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?> {
        let llm = OnDeviceLLMService.shared
        guard BetaFeaturePolicy().authorizes(.onDevice, for: .standardAnalysis) else {
            return EmailAnalysisOutcome(
                value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
                executionPath: .rules(.providerDisabled)
            )
        }
        guard llm.isModelLoaded else {
            return EmailAnalysisOutcome(
                value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
                executionPath: .rules(.modelNotLoaded)
            )
        }
        guard !msg.subject.isEmpty else {
            return EmailAnalysisOutcome(value: nil, executionPath: .beta(.onDevice))
        }
        let bodyPreview = String(msg.body.prefix(1500))
        let prompt = """
        현재 시각: \(AppDateFormat.llmString(from: now))
        발신자: \(msg.from)
        제목: \(msg.subject)
        \(bodyPreview.isEmpty ? "" : "본문:\n\(bodyPreview)")

        반드시 JSON 객체 하나만 출력하세요. 키: dueDateISO, isAllDay, sender, senderEmail, keywordScore, deadlineSentence, notes.
        dueDateISO는 명시적 마감일이 있을 때만 ISO8601로 쓰고, 없으면 빈 문자열로 두세요.
        """
        do {
            let raw = try await llm.generate(
                systemPrompt: Prompts.EmailFM.systemInstruction(language: language),
                userPrompt: prompt,
                maxTokens: 700,
                use: .standardAnalysis
            )
            return EmailAnalysisOutcome(
                value: EmailExtractionParser.parse(raw, msg: msg, now: now, language: language, provenance: .localLLM),
                executionPath: .beta(.onDevice)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return EmailAnalysisOutcome(
                value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
                executionPath: .rules(ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed)
            )
        }
    }
}

// MARK: - Shared Email Extraction Parser
enum EmailExtractionParser {
    enum Provenance {
        case localLLM
    }

    static func parse(
        _ raw: String,
        msg: GmailMessage,
        now: Date,
        language: AppLanguage,
        provenance: Provenance
    ) -> EmailExtraction? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.range(of: "{"),
              let last = trimmed.range(of: "}", options: .backwards) else {
            return nil
        }
        trimmed = String(trimmed[first.lowerBound..<last.upperBound])

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let dueDateISO = (json["dueDateISO"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dueDateISO.isEmpty,
              let dueDate = AppDateFormat.parseMailDate(dueDateISO),
              dueDate > now else {
            return nil
        }

        let sourceCalendar = AppDateFormat.sourceCalendar(for: dueDateISO)
        let normalizedDeadline = AppDateFormat.normalizedAllDayDeadline(dueDate, calendar: sourceCalendar)
        let isAllDay = ((json["isAllDay"] as? Bool) ?? false) || normalizedDeadline.isAllDay
        let finalDate = normalizedDeadline.date

        let analyzer = EmailContentAnalyzer()
        let sender = (json["sender"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let senderEmail = (json["senderEmail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keywordScore = max(0, (json["keywordScore"] as? Int) ?? 0)
        let deadlineSentence = (json["deadlineSentence"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSummary = (json["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let deadlineString = AppDateFormat.deadlineString(
            from: finalDate,
            isAllDay: isAllDay,
            language: language
        )
        var notesLines = [
            AppLanguage.localized(
                "mail.analysis.header",
                defaultValue: language == .english ? "[Email Summary]" : provenance.header(language: language),
                language: language,
                comment: "Email analysis provenance"
            ),
            {
                let defaultValue = language == .english
                    ? "Due by \(deadlineString)"
                    : "⏰ \(deadlineString)까지"
                let localized = AppLanguage.localized(
                    "mail.deadline",
                    defaultValue: defaultValue,
                    language: language,
                    comment: "Detected email deadline"
                )
                return localized == defaultValue
                    ? localized
                    : String(format: localized, locale: language.locale, deadlineString)
            }(),
        ]
        if !notesSummary.isEmpty {
            notesLines += [
                notesSummary,
                AppLanguage.localized(
                    "mail.aiSummary",
                    defaultValue: language == .english ? "(AI Summary)" : "(AI 요약)",
                    language: language,
                    comment: "AI-generated email summary marker"
                )
            ]
        }
        let resolvedSender = sender.isEmpty ? analyzer.parseSender(from: msg.from) : sender
        if !resolvedSender.isEmpty {
            notesLines += [
                "",
                {
                    let defaultValue = language == .english
                        ? "[Sender] \(resolvedSender)"
                        : "[발신자] \(resolvedSender)"
                    let localized = AppLanguage.localized(
                        "mail.sender",
                        defaultValue: defaultValue,
                        language: language,
                        comment: "Email sender label"
                    )
                    return localized == defaultValue
                        ? localized
                        : String(format: localized, locale: language.locale, resolvedSender)
                }()
            ]
        }
        return EmailExtraction(
            dueDate: finalDate,
            isAllDay: isAllDay,
            sender: resolvedSender,
            senderEmail: senderEmail.isEmpty ? analyzer.parseSenderEmail(from: msg.from) : senderEmail,
            keywordScore: keywordScore,
            deadlineSentence: deadlineSentence,
            notes: notesLines.joined(separator: "\n")
        )
    }
}

private extension EmailExtractionParser.Provenance {
    func header(language: AppLanguage) -> String {
        switch self {
        case .localLLM:
            return language == .english ? "[On-Device AI Analysis]" : "[온디바이스 AI 분석]"
        }
    }
}

struct GeminiEmailAnalysisEngine: EmailAnalysisEngine {
    private let service: GeminiProviderService

    init(service: GeminiProviderService = GeminiProviderService()) {
        self.service = service
    }

    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage
    ) async throws -> EmailAnalysisOutcome<EmailExtraction?> {
        do {
            let value = try await service.analyzeEmail(msg, now: now, language: language)
            return EmailAnalysisOutcome(value: value, executionPath: .beta(.gemini))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return EmailAnalysisOutcome(
                value: EmailContentAnalyzer().analyze(msg, now: now, language: language),
                executionPath: .rules(ProviderErrorMapper.fallbackReason(for: error) ?? .providerExecutionFailed)
            )
        }
    }
}

// MARK: - Email Analysis Engine Factory

/// 포그라운드/백그라운드에 따라 적절한 엔진을 반환한다.
/// - true (기본, 포그라운드): selectedAIProvider에 맞는 엔진
/// - false (백그라운드 BGTask): OnDeviceDetectorEngine
enum EmailAnalysisEngineFactory {
    static func makeEngine(allowFoundationModels: Bool = true) -> any EmailAnalysisEngine {
        guard allowFoundationModels else { return OnDeviceDetectorEngine(fallbackReason: .providerDisabled) }

        switch BetaFeaturePolicy().routingDecision(for: .standardAnalysis) {
        case .rules(let reason):
            return OnDeviceDetectorEngine(fallbackReason: reason)
        case .providers(let providers):
            switch providers.first {
            case .foundationModels:
                return FoundationModelsEmailEngine()
            case .onDevice:
                return LocalLLMEmailAnalysisEngine()
            case .gemini:
                return GeminiEmailAnalysisEngine()
            case nil:
                return OnDeviceDetectorEngine(fallbackReason: .noEligibleProvider)
            }
        }
    }
}
