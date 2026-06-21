import Foundation

// MARK: - Email Analysis Engine Protocol

/// 이메일 제목·본문·발신자를 받아 마감일 추출 결과를 반환하는 엔진 프로토콜.
///
/// 현재 구현: OnDeviceDetectorEngine (NSDataDetector 기반, 항상 안전하게 출시 가능).
/// 전환 중: OnDeviceLLMEmailEngine (Qwen 4B MLX, Phase B에서 실 구현 — Phase A는 스텁).
/// 보류: FoundationModelsEmailEngine (iOS 27 GA + Xcode 27 정식 이후 재검토).
///
/// ⚠️ 프라이버시 불변식 — 메일 본문은 다음 엔진에만 전달 가능:
///   1. OnDeviceDetectorEngine (완전 온디바이스)
///   2. OnDeviceLLMEmailEngine (온디바이스 Qwen/MLX)
///   3. FoundationModelsEmailEngine (Apple 온디바이스 모델 / Apple PCC — 보류)
/// 절대 외부 서드파티 클라우드(Claude·OpenAI·Gemini 등)로 전달하지 않는다.
/// CloudIntelligenceEngine은 메타데이터(제목·마감·태그·페르소나) 전용.
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
/// C: 스텁에서 실 구현으로 전환. FoundationModelsService.analyzeEmail()을 호출한다.
/// 포그라운드 전용 — makeEngine(allowFoundationModels: false) 경로(백그라운드)에서는 미사용.
///
/// ⚠️ 프라이버시 불변식:
///   - AFM은 Apple 온디바이스 / PCC — 외부 서드파티 미라우팅.
///   - 이메일 본문은 이 엔진에만 전달 가능. CloudIntelligenceEngine 금지.
struct FoundationModelsEmailEngine: EmailAnalysisEngine {
    private let fallback = OnDeviceDetectorEngine()

    func analyze(_ msg: GmailMessage, now: Date) async -> EmailExtraction? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
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

// MARK: - On-Device LLM Email Engine (스텁 — Phase B에서 실 구현)

/// Qwen 4B MLX 온디바이스 LLM 기반 메일 분석 엔진.
///
/// 모델 로드 시: LLM으로 제목·마감일·triage·AI 요약 추출.
/// 모델 미로드/OOM/실패 시: OnDeviceDetectorEngine(NSDataDetector)으로 자동 폴백.
///
/// ⚠️ 프라이버시 불변식: 메일 본문은 온디바이스에서만 처리, 외부 전송 금지.
struct OnDeviceLLMEmailEngine: EmailAnalysisEngine {
    private let fallback = OnDeviceDetectorEngine()

    private static let systemPrompt = Prompts.EmailLLM.systemInstruction

    func analyze(_ msg: GmailMessage, now: Date) async -> EmailExtraction? {
        let service = OnDeviceLLMService.shared
        guard service.isModelLoaded else {
            return await fallback.analyze(msg, now: now)
        }

        let userPrompt = "발신자: \(msg.from)\n제목: \(msg.subject)\n본문:\n\(String(msg.body.prefix(2_000)))"

        do {
            let json = try await service.generate(
                systemPrompt: Self.systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 256
            )
            return parseExtraction(json: json, msg: msg, now: now)
        } catch {
            return await fallback.analyze(msg, now: now)
        }
    }

    func parseExtraction(json: String, msg: GmailMessage, now: Date) -> EmailExtraction? {
        var t = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t.range(of: "{"), let e = t.range(of: "}", options: .backwards) {
            t = String(t[s.lowerBound...e.lowerBound])
        }
        guard let data   = t.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // 마감일 파싱
        var finalDate: Date
        var isAllDay = false
        if let ds = parsed["dueDate"] as? String, ds != "null", !ds.isEmpty {
            guard let d = AppDateFormat.parseLLMDate(ds), d > now else { return nil }
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
            if comps.hour == 0 && comps.minute == 0 && (comps.second ?? 0) == 0 {
                isAllDay = true
                var eod = Calendar.current.dateComponents([.year, .month, .day], from: d)
                eod.hour = 23; eod.minute = 59
                finalDate = Calendar.current.date(from: eod) ?? d
            } else {
                finalDate = d
            }
        } else {
            return nil
        }

        let notesAI    = parsed["notes"] as? String ?? ""
        let triageStr  = parsed["triage"] as? String ?? "review"
        let analyzer   = EmailContentAnalyzer()
        let sender     = analyzer.parseSender(from: msg.from)
        let senderEmail = analyzer.parseSenderEmail(from: msg.from)
        let df         = DateFormatter()
        df.locale      = Locale(identifier: "ko_KR")
        df.dateStyle   = .long
        df.timeStyle   = isAllDay ? .none : .short
        var notesLines = ["⏰ \(df.string(from: finalDate))까지"]
        if !notesAI.isEmpty { notesLines += [notesAI, "(AI 요약)"] }
        if !sender.isEmpty  { notesLines += ["", "[발신자] \(sender)"] }

        return EmailExtraction(
            dueDate:          finalDate,
            isAllDay:         isAllDay,
            sender:           sender,
            senderEmail:      senderEmail,
            keywordScore:     triageStr == "todo" ? 1 : 0,
            deadlineSentence: notesAI,
            notes:            notesLines.joined(separator: "\n")
        )
    }
}

// MARK: - Email Analysis Engine Key (설정 저장 키)

/// 사용자가 선택한 이메일 분석 엔진.
/// onDeviceLLM: 기기 지원(8GB+) 시 노출. onDevice는 항상 사용 가능.
/// foundationModels: iOS 27 GA 이후 재검토(현재 보류), 설정 UI에서 미노출.
enum EmailAnalysisEngineKey: String, CaseIterable {
    case onDevice        = "onDevice"          // OnDeviceDetectorEngine (기본, 항상 사용 가능)
    case onDeviceLLM     = "onDeviceLLM"       // OnDeviceLLMEmailEngine (Qwen/MLX, Phase B)
    case foundationModels = "foundationModels" // FoundationModelsEmailEngine (보류 — iOS 27 GA 이후)

    var displayName: String {
        switch self {
        case .onDevice:         "온디바이스 감지 (기본)"
        case .onDeviceLLM:      "온디바이스 AI (Qwen)"
        case .foundationModels: "Apple AI (온디바이스/PCC)"
        }
    }
}

// MARK: - Email Analysis Engine Factory

/// 포그라운드/백그라운드에 따라 적절한 엔진을 반환한다.
///
/// C: allowFoundationModels 파라미터로 포그라운드/백그라운드 분기.
///   - true (기본, 포그라운드): FoundationModelsEmailEngine → AFM 온디바이스 분석 (미가용 시 NSDataDetector 폴백)
///   - false (백그라운드 BGTask): OnDeviceDetectorEngine → NSDataDetector (ANE 백그라운드 미사용)
///
/// 저장키(pieroot.todo.emailAnalysisEngine) 및 OnDeviceLLMEmailEngine은 vestigial —
/// 이 팩토리는 allowFoundationModels만 보며 저장키로 분기하지 않는다.
enum EmailAnalysisEngineFactory {
    static let settingsKey = "pieroot.todo.emailAnalysisEngine"  // vestigial — 무시됨

    static func makeEngine(allowFoundationModels: Bool = true) -> any EmailAnalysisEngine {
        if allowFoundationModels {
            // 포그라운드: AFM 강제 (미가용 시 내부에서 NSDataDetector 폴백)
            return FoundationModelsEmailEngine()
        }
        // 백그라운드: NSDataDetector (결정론적, ANE 미사용)
        return OnDeviceDetectorEngine()
    }
}
