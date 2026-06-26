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
/// C: 스텁에서 실 구현으로 전환. FoundationModelsService.analyzeEmail()을 호출한다.
/// 포그라운드 전용 — makeEngine(allowFoundationModels: false) 경로(백그라운드)에서는 미사용.
///
/// ⚠️ 프라이버시 불변식:
///   - AFM은 Apple 온디바이스 / PCC — 외부 서비스 미라우팅.
///   - 이메일 본문은 이 엔진에만 전달 가능.
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

// MARK: - Email Analysis Engine Factory

/// 포그라운드/백그라운드에 따라 적절한 엔진을 반환한다.
/// - true (기본, 포그라운드): FoundationModelsEmailEngine → AFM 온디바이스 (미가용 시 NSDataDetector 폴백)
/// - false (백그라운드 BGTask): OnDeviceDetectorEngine → NSDataDetector (ANE 백그라운드 미사용)
enum EmailAnalysisEngineFactory {
    static func makeEngine(allowFoundationModels: Bool = true) -> any EmailAnalysisEngine {
        if allowFoundationModels {
            return FoundationModelsEmailEngine()
        }
        return OnDeviceDetectorEngine()
    }
}
