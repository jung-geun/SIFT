import Foundation
import Combine
import SwiftData
import UIKit

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
/// 게이팅 조건 (isEligible):
///   ① pieroot.todo.onDeviceLLMEnabled == true (UI: "AI 자동화" 토글)
///   ② 마지막 실행 후 6시간 쿨다운 경과
///   ③ 배터리 25% 이상 또는 충전 중
@MainActor
final class LLMAutomationOrchestrator: ObservableObject {

    static let shared = LLMAutomationOrchestrator()

    /// LLM GPU 추론 실행 중이면 true — UI에서 "앱 이탈 금지" 경고 배너를 표시하는 데 사용.
    @Published private(set) var isRunning = false

    // MARK: - 설정 상수

    private let cooldownInterval: TimeInterval      = 6 * 3600        // 6시간 쿨다운
    private let personaUpdateInterval: TimeInterval = 3 * 24 * 3600   // 3일 페르소나 갱신 주기
    private let minBatteryLevel: Float              = 0.25            // 배터리 25% 미만 시 스킵

    // MARK: - UserDefaults 키

    private static let lastRunKey     = "pieroot.todo.lastLLMAutomationDate"
    private static let lastPersonaKey = "pieroot.todo.lastPersonaUpdateDate"

    private init() {}

    // MARK: - 진입점

    /// 조건 충족 시 LLM 자동화 파이프라인을 실행한다.
    /// 조건 미충족 시 즉시 반환(no-op). UI 스레드를 차단하지 않으며 실패는 조용히 삼킨다.
    func runIfEligible(context: ModelContext) async {
        let allowFoundationModels = UserDefaults.standard.bool(forKey: "pieroot.todo.onDeviceLLMEnabled")
        let emailAutoEnabled = UserDefaults.standard.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled")

        guard canRunAutomation() else { return }
        guard emailAutoEnabled || allowFoundationModels else { return }

        isRunning = true
        defer { isRunning = false }

        // 실행 시각 저장 (쿨다운 시작)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)

        // 1. 이메일 → 할 일 + 캘린더 등록 (메일 자동 분석 토글이 켜진 경우만)
        if emailAutoEnabled {
            _ = await runEmailPipeline(context: context, allowFoundationModels: allowFoundationModels)
        }

        // 2. 페르소나 자동 갱신 (주기 행위) — AI 토글이 켜진 경우만 실행
        guard allowFoundationModels else { return }
        await maybeUpdatePersona(context: context)
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
    private func runEmailPipeline(context: ModelContext, allowFoundationModels: Bool) async -> Bool {
        guard EmailService.shared.isAuthenticated else { return false }
        do {
            let existing     = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
            let existingRefs = Set(existing.map { $0.sourceRef })
            let (todos, events) = try await EmailService.shared.fetchAndExtractAll(
                allowFoundationModels: allowFoundationModels,
                excludingAlreadyHandledMessageIDs: existingRefs
            )

            // 중복 방지: sourceRef로 기존 항목 비교
            let freshTodos = todos.filter { !existingRefs.contains($0.sourceRef) }
            for todo in freshTodos {
                context.insert(todo)
                // 긴급·최우선 항목 캘린더 자동 등록 정책 적용
                CalendarService.shared.applyAutoRegistration(for: todo)
            }

            // 이메일에서 추출한 캘린더 이벤트 자동 등록
            if CalendarService.shared.isAuthorized && CalendarAutoPolicy.isAuto {
                let iso = ISO8601DateFormatter()
                for (event, sourceRef) in events {
                    guard !CalendarService.shared.hasEvent(forEmailRef: sourceRef),
                          let start = iso.date(from: event.startISO) else { continue }
                    let end = event.endISO.isEmpty ? nil : iso.date(from: event.endISO)
                    _ = try? CalendarService.shared.createEventFromEmail(
                        title: event.title, start: start, end: end,
                        isAllDay: event.isAllDay, location: event.location,
                        notes: event.notes, sourceRef: sourceRef
                    )
                }
            }

            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pieroot.todo.lastEmailFetchDate")
            print("[LLMOrchestrator] 이메일 파이프라인 완료 (\(todos.count)개 처리)")
            return true
        } catch {
            print("[LLMOrchestrator] 이메일 파이프라인 실패: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 페르소나 자동 갱신

    /// 마지막 갱신으로부터 `personaUpdateInterval` 이상 경과 시 온디바이스 LLM으로 페르소나를 개선한다.
    /// 기존 buildPrompt/parseText 재사용 — 이메일 본문 미포함, 프라이버시 불변식 유지.
    private func maybeUpdatePersona(context: ModelContext) async {
        let lastUpdate = UserDefaults.standard.double(forKey: Self.lastPersonaKey)
        guard lastUpdate == 0 || Date().timeIntervalSince1970 - lastUpdate >= personaUpdateInterval else {
            return
        }

        let todos    = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let personaDescriptor = FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let personas = (try? context.fetch(personaDescriptor)) ?? []
        let existing = personas.first?.descriptionText ?? ""

        do {
            let result = try await PersonaGenerationService().generateWithOnDeviceLLM(
                existingPersona: existing,
                todos: todos
            )
            // SwiftData upsert: 기존 페르소나 업데이트 또는 신규 삽입
            if let persona = personas.first {
                persona.descriptionText = result.personaText
                persona.updatedAt       = Date()
            } else {
                context.insert(Persona(descriptionText: result.personaText))
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastPersonaKey)
            print("[LLMOrchestrator] 페르소나 자동 갱신 완료")
        } catch {
            print("[LLMOrchestrator] 페르소나 갱신 실패: \(error.localizedDescription)")
        }
    }
}
