import Foundation
import Combine
import SwiftData
import UIKit
import OSLog

/// 포그라운드 AI 자동화 오케스트레이터.
///
/// 앱 활성화(scenePhase == .active) 시 todoApp에서 호출된다.
/// E: Qwen 하드 요구에서 분리 — AFM(ANE)으로 포그라운드 자동화.
/// Qwen 미다운로드 시에도 AFM으로 이메일 분석·페르소나 갱신이 실행된다.
///
/// 실행 시퀀스:
///   1. 이메일 fetch → AFM 분석 → 할 일 + 캘린더 자동 등록
///   2. 페르소나 자동 갱신 (설정 주기 경과 시, AFM 사용)
///
/// ⚠️ 프라이버시 불변식: 이메일 본문은 온디바이스(AFM/PCC)에서만 처리. 외부 전송 없음.
///
/// Foreground email automation orchestrator.
///
/// Email analysis uses an explicitly opted-in beta provider or deterministic
/// rules. Persona descriptions are never overwritten automatically.
@MainActor
final class EmailAutomationOrchestrator: ObservableObject {

    static let shared = EmailAutomationOrchestrator()

    /// LLM GPU 추론 실행 중이면 true — UI에서 "앱 이탈 금지" 경고 배너를 표시하는 데 사용.
    @Published private(set) var isRunning = false

    // MARK: - 설정 상수

    private let cooldownInterval: TimeInterval      = 6 * 3600        // 6시간 쿨다운
    private let minBatteryLevel: Float              = 0.25            // 배터리 25% 미만 시 스킵
    private let logger = Logger(subsystem: "pieroot.todo", category: "LLMAutomation")

    // MARK: - UserDefaults 키

    private static let lastRunKey     = "pieroot.todo.lastLLMAutomationDate"

    private init() {}

    // MARK: - 진입점

    /// Runs only the user-enabled email automation pipeline.
    func runIfEligible(context: ModelContext) async {
        let emailAutoEnabled = UserDefaults.standard.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled")
        guard emailAutoEnabled, canRunAutomation() else { return }

        isRunning = true
        defer { isRunning = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
        _ = await runEmailPipeline(
            context: context,
            allowFoundationModels: BetaFeaturePolicy().authorizes(
                .foundationModels,
                for: .standardAnalysis
            )
        )
    }


    // MARK: - 게이팅

    private func canRunAutomation() -> Bool {
        // ① 쿨다운: 마지막 실행 후 6시간 미경과 시 스킵
        let lastRun = UserDefaults.standard.double(forKey: Self.lastRunKey)
        if lastRun > 0, Date().timeIntervalSince1970 - lastRun < cooldownInterval { return false }

        // ② 배터리 (시뮬레이터는 .unknown → 허용)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        let level = UIDevice.current.batteryLevel
        if state != .unknown && state != .charging && state != .full
            && level >= 0 && level < minBatteryLevel {
            return false
        }

        return true
    }


    // MARK: - 이메일 파이프라인

    /// EmailService로 이메일을 가져와 온디바이스 분석 후 Todo + 캘린더에 등록한다.
    /// FM 토글이 꺼져 있으면 FoundationModels 분석 대신 규칙 기반 경로로 폴백한다.
    @discardableResult
    private func runEmailPipeline(context _: ModelContext, allowFoundationModels _: Bool) async -> Bool {
        guard let account = UserDefaults.standard.string(forKey: "pieroot.todo.imap.account"),
              !account.isEmpty,
              IMAPCredentialStore.hasCredential(for: account),
              !IMAPCredentialStore.isCredentialRejected(for: account)
        else { return false }
        do {
            let emailContext = ModelContext(AppDataContainer.shared.emailContainer)
            _ = try await GmailIMAPIngestionService(emailContext: emailContext)
                .sync(
                    account: account,
                    backgroundEnabled: UserDefaults.standard.bool(
                        forKey: "pieroot.todo.imap.backgroundEnabled"
                    )
                )
            return true
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "mail.gmail",
                operation: "pipeline"
            )
            if case GmailIMAPError.credentialRejected = error {
                IMAPCredentialStore.markCredentialRejected(for: account)
            }
            logger.error("Gmail IMAP pipeline failed: \(error.localizedDescription)")
            // Authentication and Keychain availability can fail transiently during
            // launch. Stored App Passwords are deleted only by explicit sign-out.
            return false
        }
    }


}
