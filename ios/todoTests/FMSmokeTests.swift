import Foundation
import Testing
@testable import todo

// MARK: - Tier 2: FM 라이브 스모크 테스트
//
// Apple Foundation Models(@Generable)가 올바른 구조체 필드를 채우는지 실기기/시뮬레이터에서 검증.
// 각 테스트는 `if #available(iOS 26.0, *)` + `guard FoundationModelsAvailability.isAvailable` 패턴으로 게이팅:
//   - iOS 26 미만: 가용성 블록 진입 안 함 → 테스트 즉시 pass
//   - FM 미지원 기기/시뮬레이터: FoundationModelsAvailability.isAvailable == false → return (trivial pass)
//   - FM 지원 환경: 전체 검증 실행
//
// 실행 조건:
//   - iPhone 15 Pro+ 또는 M-시리즈 iPad (Apple Intelligence 활성화)
//   - iOS 26.0+, Xcode 26+
//   - 설정 > Apple Intelligence & Siri 활성화

// MARK: - 가용성 메시징

@Suite("FM availability messaging")
struct FMAvailabilityMessagingTests {

    @Test("available returns nil")
    func availableReturnsNil() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: true,
            iOSMajorVersion: 27,
            isSimulator: false,
            frameworkLinked: true
        )
        #expect(reason == nil)
    }

    @Test("simulator returns simulator copy")
    func simulatorReturnsSimulatorCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 27,
            isSimulator: true,
            frameworkLinked: true,
            language: .korean
        )
        #expect(reason == "시뮬레이터에서는 Apple Foundation Models를 비활성화합니다. 실기기에서 Apple Intelligence 및 Siri 설정을 확인하세요.")
    }

    @Test("missing framework returns support copy")
    func missingFrameworkReturnsSupportCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 27,
            isSimulator: false,
            frameworkLinked: false,
            language: .korean
        )
        #expect(reason == "Apple Foundation Models는 iOS 26 이상 및 FoundationModels.framework가 있는 빌드에서만 사용할 수 있습니다.")
    }

    @Test("iOS 26 returns Apple Intelligence activation copy")
    func iOS26ReturnsAppleIntelligenceActivationCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 26,
            isSimulator: false,
            frameworkLinked: true,
            language: .korean
        )
        #expect(reason == "Apple Foundation Models는 Apple Intelligence를 사용할 수 있고 활성화된 기기에서만 사용할 수 있습니다. 설정 > Apple Intelligence 및 Siri에서 활성화 상태를 확인하세요.")
    }

    @Test("iOS 27 returns Siri AI language copy")
    func iOS27ReturnsSiriAILanguageCopy() {
        let reason = FoundationModelsAvailability.unavailableExplanation(
            isAvailable: false,
            iOSMajorVersion: 27,
            isSimulator: false,
            frameworkLinked: true,
            language: .korean
        )
        #expect(reason == "Apple Foundation Models는 현재 Siri AI를 사용할 수 있는 영어권 Siri 언어 및 Apple Intelligence 활성화 환경에서만 사용할 수 있습니다. 설정 > Apple Intelligence 및 Siri에서 언어와 활성화 상태를 확인하세요.")
    }
}

#if canImport(FoundationModels)
import FoundationModels

// MARK: - 가용성 프로브

@Suite("FM 가용성 프로브")
struct FMAvailabilityProbeTests {

    /// availability 값을 콘솔에 출력하는 프로브.
    /// .available: Tier 2 실행 가능. 그 외: FM 미지원 환경 — Tier 2 skip(정상).
    @Test("Apple Intelligence availability 콘솔 출력")
    func probeAvailability() {
        print("[FM 프로브] FoundationModelsAvailability.isAvailable = \(FoundationModelsAvailability.isAvailable)")
        if let reason = FoundationModelsAvailability.unavailableExplanation {
            print("[FM 프로브] FoundationModelsAvailability.unavailableExplanation = \(reason)")
        }
        // 이 테스트는 환경 무관 항상 pass — 콘솔 출력으로 지원 여부 확인
        #expect(Bool(true))
    }
}


// MARK: - 우선순위 랭킹 스모크

@Suite("FM 우선순위 랭킹 스모크")
struct FMRankingsSmokeTests {

    @Test("rankTodos: score 0.01~1.0, todoID 역참조 성공")
    func rankTodosSmoke() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsAvailability.isAvailable else { return }
            let service = FoundationModelsService()
            var todos = makeTodos(["iOS 26 마이그레이션", "주간 회의 준비", "유닛 테스트 작성"])
            todos[0].dueDate = Date().addingTimeInterval(86_400 * 3)   // 3일 후 마감
            let persona = PersonaContext(types: [], description: "iOS 개발자")
            let results = try await service.rankTodos(todos: todos, events: [], persona: persona)

            #expect(!results.isEmpty, "랭킹 결과가 비어 있어서는 안 됩니다")
            for r in results {
                #expect(r.score >= 0.01, "score 하한 위반: \(r.score)")
                #expect(r.score <= 1.0, "score 상한 위반: \(r.score)")
                let matched = todos.contains { $0.id == r.todoID }
                #expect(matched, "역참조 실패: \(r.todoID)")
            }
        }
    }

}

// MARK: - 이메일 마감 추출 스모크

@Suite("FM 이메일 마감 추출 스모크")
struct FMEmailSmokeTests {

    @Test("마감 포함 메일 → dueDate > now (추론 정상)")
    func analyzeEmailWithDeadline() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsAvailability.isAvailable else { return }
            let now = Date()
            let service = FoundationModelsService()
            let msg = GmailMessage(
                id: "smoke-1", threadID: "t1", messageID: "<smoke1@test>",
                subject: "프로젝트 제안서 제출 요청",
                from: "김팀장 <manager@company.com>",
                snippet: "이번 주 금요일까지 제출 부탁드립니다",
                body: "안녕하세요. 프로젝트 제안서를 이번 주 금요일(2026년 6월 26일)까지 제출해 주시기 바랍니다. 감사합니다.",
                htmlBody: nil,
                receivedAt: now,
                labelIds: [], isBulk: false
            )
            if let extraction = try await service.analyzeEmail(msg, now: now) {
                #expect(extraction.dueDate > now, "추출된 마감일이 현재보다 미래여야 합니다")
                #expect(!extraction.sender.isEmpty, "발신자가 비어 있어서는 안 됩니다")
            }
            // nil도 허용 — smoke test는 crash 부재만 보장
        }
    }

    @Test("마감 없는 메일 → nil (추측 금지 검증)")
    func analyzeEmailWithoutDeadline() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsAvailability.isAvailable else { return }
            let now = Date()
            let service = FoundationModelsService()
            let msg = GmailMessage(
                id: "smoke-2", threadID: "t2", messageID: "<smoke2@test>",
                subject: "점심 메뉴 추천",
                from: "동료 <colleague@company.com>",
                snippet: "오늘 점심 뭐 먹을까요?",
                body: "오늘 점심 메뉴 추천해주세요. 한식? 중식?",
                htmlBody: nil,
                receivedAt: now,
                labelIds: [], isBulk: false
            )
            let result = try await service.analyzeEmail(msg, now: now)
            #expect(result == nil, "마감 없는 메일에서 EmailExtraction 반환 금지 (dueDateISO 추측 금지)")
        }
    }
}

// MARK: - 헬퍼

private func makeTodos(_ titles: [String]) -> [Todo] {
    titles.map { title in
        var t = Todo()
        t.title = title
        return t
    }
}

#endif // canImport(FoundationModels)
