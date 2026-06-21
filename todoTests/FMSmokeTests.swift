import Foundation
import Testing
@testable import todo

// MARK: - Tier 2: FM 라이브 스모크 테스트
//
// Apple Foundation Models(@Generable)가 올바른 구조체 필드를 채우는지 실기기/시뮬레이터에서 검증.
// 각 테스트는 `if #available(iOS 26.0, *)` + `guard isAvailable` 패턴으로 게이팅:
//   - iOS 26 미만: 가용성 블록 진입 안 함 → 테스트 즉시 pass
//   - FM 미지원 기기/시뮬레이터: isAvailable == false → return (trivial pass)
//   - FM 지원 환경: 전체 검증 실행
//
// 실행 조건:
//   - iPhone 15 Pro+ 또는 M-시리즈 iPad (Apple Intelligence 활성화)
//   - iOS 26.0+, Xcode 26+
//   - 설정 > Apple Intelligence & Siri 활성화

#if canImport(FoundationModels)
import FoundationModels

// MARK: - 가용성 프로브

@Suite("FM 가용성 프로브")
struct FMAvailabilityProbeTests {

    /// availability 값을 콘솔에 출력하는 프로브.
    /// .available: Tier 2 실행 가능. 그 외: FM 미지원 환경 — Tier 2 skip(정상).
    @Test("Apple Intelligence availability 콘솔 출력")
    func probeAvailability() {
        if #available(iOS 26.0, *) {
            let av = SystemLanguageModel.default.availability
            print("[FM 프로브] SystemLanguageModel.default.availability = \(av)")
        }
        // 이 테스트는 환경 무관 항상 pass — 콘솔 출력으로 지원 여부 확인
        #expect(Bool(true))
    }
}

// MARK: - 페르소나 생성 스모크

@Suite("FM 페르소나 생성 스모크")
struct FMPersonaSmokeTests {

    @Test("generatePersona: personaText 비어있지 않음, insights 각 항목 유효")
    func generatePersonaSmoke() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsService.isAvailable else { return }
            let service = FoundationModelsService()
            let todos = makeTodos(["SwiftUI 앱 개발", "머신러닝 논문 읽기", "코드 리뷰 완료"])
            let (personaText, insights) = try await service.generatePersona(existingPersona: "", todos: todos)

            #expect(!personaText.isEmpty, "personaText가 비어 있어서는 안 됩니다")
            for insight in insights {
                #expect(!insight.isEmpty, "빈 insight가 포함되어서는 안 됩니다")
            }
        }
    }
}

// MARK: - 우선순위 랭킹 스모크

@Suite("FM 우선순위 랭킹 스모크")
struct FMRankingsSmokeTests {

    @Test("rankTodos: score 0.01~1.0, todoID 역참조 성공")
    func rankTodosSmoke() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsService.isAvailable else { return }
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

// MARK: - 행동 패턴 인사이트 스모크

@Suite("FM 패턴 인사이트 스모크")
struct FMPatternInsightsSmokeTests {

    @Test("generatePatternInsights: insights 반환, 조언 키워드 부재 (A-1 회귀 가드)")
    func generatePatternInsightsSmoke() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsService.isAvailable else { return }
            let service = FoundationModelsService()
            let summary = "주요 집중 시간대: 22:00~01:00. 평균 착수 지연: 2.3일. 빠른 완료 유형: 단순 반복 업무(15분). 지연 유형: 문서 작성(3일+)."
            let todos = makeTodos(["문서 작성", "코드 리뷰"])
            let insights = try await service.generatePatternInsights(summary: summary, todos: todos)

            for insight in insights {
                #expect(!insight.isEmpty, "빈 insight가 있습니다")
                // 회귀 가드: PatternInsights 명시적 조언 금지 (A-1 정합화)
                // "하세요"는 관찰 서술문에도 출현 가능한 폴라이트 어미라 제외,
                // 명백한 권고 표현만 체크한다.
                let lower = insight.lowercased()
                let hasExplicitAdvice = lower.contains("해보세요")
                    || lower.contains("하는 것이 좋")
                    || lower.contains("을 권장합니다")
                    || lower.contains("하시기 바랍니다")
                #expect(!hasExplicitAdvice, "명시적 조언 키워드 발견됨: \(insight)")
            }
        }
    }

    @Test("빈 summary → 빈 배열 반환 (guard 확인)")
    func emptySummaryReturnsEmpty() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsService.isAvailable else { return }
            let service = FoundationModelsService()
            let insights = try await service.generatePatternInsights(summary: "", todos: [])
            #expect(insights.isEmpty, "빈 summary에서 insights가 반환되어서는 안 됩니다")
        }
    }
}

// MARK: - 이메일 마감 추출 스모크

@Suite("FM 이메일 마감 추출 스모크")
struct FMEmailSmokeTests {

    @Test("마감 포함 메일 → dueDate > now (추론 정상)")
    func analyzeEmailWithDeadline() async throws {
        if #available(iOS 26.0, *) {
            guard FoundationModelsService.isAvailable else { return }
            let now = Date()
            let service = FoundationModelsService()
            let msg = GmailMessage(
                id: "smoke-1", threadID: "t1", messageID: "<smoke1@test>",
                subject: "프로젝트 제안서 제출 요청",
                from: "김팀장 <manager@company.com>",
                snippet: "이번 주 금요일까지 제출 부탁드립니다",
                body: "안녕하세요. 프로젝트 제안서를 이번 주 금요일(2026년 6월 26일)까지 제출해 주시기 바랍니다. 감사합니다.",
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
            guard FoundationModelsService.isAvailable else { return }
            let now = Date()
            let service = FoundationModelsService()
            let msg = GmailMessage(
                id: "smoke-2", threadID: "t2", messageID: "<smoke2@test>",
                subject: "점심 메뉴 추천",
                from: "동료 <colleague@company.com>",
                snippet: "오늘 점심 뭐 먹을까요?",
                body: "오늘 점심 메뉴 추천해주세요. 한식? 중식?",
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
