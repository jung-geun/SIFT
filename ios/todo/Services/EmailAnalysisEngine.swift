import Foundation

// MARK: - Email Analysis Engine Protocol

/// 이메일 제목·본문·발신자를 받아 마감일 추출 결과를 반환하는 엔진 프로토콜.
///
/// 포그라운드: FoundationModelsEmailEngine (AFM 온디바이스, 미가용 시 NSDataDetector 폴백).
/// 백그라운드: OnDeviceDetectorEngine (NSDataDetector, 결정론적).
///
/// ⚠️ 프라이버시 불변식 — 메일 본문은 온디바이스 엔진에만 전달.
/// 절대 외부 서비스로 전달하지 않는다.
protocol EmailAnalysisEngine {
    /// GmailMessage를 분석해 마감일을 추출한다.
    /// - Parameters:
    ///   - msg: 분석할 Gmail 메시지 (subject + body + from 헤더 포함)
    ///   - now: 기준 시각 (테스트·재현 가능성을 위해 주입)
    /// - Returns: 마감일이 감지되면 EmailExtraction, 없으면 nil
    func analyze(_ msg: GmailMessage, now: Date) async -> EmailExtraction?
}

// MARK: - On-Device Detector Engine (현재 기본 엔진)

/// NSDataDetector 기반 온디바이스 분석 엔진.
/// EmailContentAnalyzer를 래핑한다. 네트워크·AFM 없이 완전 로컬.
struct OnDeviceDetectorEngine: EmailAnalysisEngine {
    private let analyzer = EmailContentAnalyzer()

    func analyze(_ msg: GmailMessage, now: Date) async -> EmailExtraction? {
        analyzer.analyze(msg, now: now)
    }
}

// MARK: - Foundation Models Email Engine (C: AFM 실 구현)

/// Apple Foundation Models(온디바이스 / PCC) 기반 분석 엔진.
///
/// 포그라운드 전용 — makeEngine(allowFoundationModels: false) 경로(백그라운드)에서는 미사용.
/// 이메일 본문은 Apple 온디바이스 / PCC 경로로만 전달한다.
struct FoundationModelsEmailEngine: EmailAnalysisEngine {
    private let fallback = OnDeviceDetectorEngine()

    func analyze(_ msg: GmailMessage, now: Date) async -> EmailExtraction? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsAvailability.isAvailable {
            do {
                return try await FoundationModelsService().analyzeEmail(msg, now: now)
            } catch {
                print("[FoundationModelsEmailEngine] FM 실패 — NSDataDetector 폴백: \(error.localizedDescription)")
            }
        }
        #endif
        return await fallback.analyze(msg, now: now)
    }
}

// MARK: - Gemini Email Engine (opt-in only)

private enum ProviderEmailAnalysisSettings {
    static let enabledKey = "pieroot.todo.providerEmailAnalysisEnabled"

    static var selectedProvider: PersonaAIProvider {
        SettingsStore.selectedProvider()
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var shouldUseGemini: Bool {
        selectedProvider == .gemini && isEnabled && GeminiProviderService.storedAPIKey != nil
    }
}

struct GeminiEmailAnalysisEngine: EmailAnalysisEngine {
    private let providerService: GeminiProviderService
    private let fallback = OnDeviceDetectorEngine()
    private let analyzer = EmailContentAnalyzer()

    init(providerService: GeminiProviderService = GeminiProviderService()) {
        self.providerService = providerService
    }

    func analyze(_ msg: GmailMessage, now: Date) async -> EmailExtraction? {
        let bodyPreview = String(msg.body.prefix(1500))
        guard !msg.subject.isEmpty else { return nil }

        let prompt = """
현재 시각: \(AppDateFormat.llmString(from: now))
발신자: \(msg.from)
제목: \(msg.subject)
\(bodyPreview.isEmpty ? "" : "본문:\n\(bodyPreview)")
"""

        do {
            let raw = try await providerService.generateJSON(
                systemInstruction: Prompts.EmailFM.systemInstruction,
                userPrompt: prompt,
                modelID: GeminiProviderService.storedModelID
            )
            return parseExtraction(raw, msg: msg, now: now)
        } catch {
            print("[GeminiEmailAnalysisEngine] Gemini 실패 — NSDataDetector 폴백: \(error.localizedDescription)")
            return await fallback.analyze(msg, now: now)
        }
    }

    private func parseExtraction(_ raw: String, msg: GmailMessage, now: Date) -> EmailExtraction? {
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
              let dueDate = AppDateFormat.parseLLMDate(dueDateISO),
              dueDate > now else {
            return nil
        }

        var isAllDay = (json["isAllDay"] as? Bool) ?? false
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: dueDate)
        var finalDate = dueDate
        if comps.hour == 0 && comps.minute == 0 && (comps.second ?? 0) == 0 {
            isAllDay = true
            var eod = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
            eod.hour = 23
            eod.minute = 59
            finalDate = Calendar.current.date(from: eod) ?? dueDate
        }

        let sender = (json["sender"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let senderEmail = (json["senderEmail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keywordScore = max(0, (json["keywordScore"] as? Int) ?? 0)
        let deadlineSentence = (json["deadlineSentence"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSummary = (json["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let df = DateFormatter()
        df.locale = Locale(identifier: "ko_KR")
        df.dateStyle = .long
        df.timeStyle = isAllDay ? .none : .short

        var notesLines = ["[Gemini 분석]", "⏰ \(df.string(from: finalDate))까지"]
        if !notesSummary.isEmpty { notesLines += [notesSummary, "(AI 요약)"] }
        let resolvedSender = sender.isEmpty ? analyzer.parseSender(from: msg.from) : sender
        if !resolvedSender.isEmpty { notesLines += ["", "[발신자] \(resolvedSender)"] }

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

// MARK: - Email Analysis Engine Factory

/// 포그라운드/백그라운드에 따라 적절한 엔진을 반환한다.
/// - Gemini provider email analysis는 명시적 opt-in일 때만 활성화된다.
/// - true (기본, 포그라운드): Gemini opt-in → GeminiEmailAnalysisEngine, 아니면 FoundationModelsEmailEngine
/// - false (백그라운드 BGTask): OnDeviceDetectorEngine
enum EmailAnalysisEngineFactory {
    static func makeEngine(allowFoundationModels: Bool = true) -> any EmailAnalysisEngine {
        if allowFoundationModels && ProviderEmailAnalysisSettings.shouldUseGemini {
            return GeminiEmailAnalysisEngine()
        }
        if allowFoundationModels {
            return FoundationModelsEmailEngine()
        }
        return OnDeviceDetectorEngine()
    }
}
