import Foundation

// MARK: - 수동 추가 시 온디바이스 AFM 약한 정렬 서비스
//
// TODO를 수동으로 추가하는 즉시 해당 항목만 온디바이스 AFM(ANE)으로 단일 분석해
// 근사 우선순위 점수를 부여한다.
//
// 설계 원칙:
//   - 클라우드 미사용: IntelligenceServiceFactory(사용자 선택 provider)를 우회하고
//     FoundationModelsEngine을 직접 인스턴스화 → 항상 온디바이스.
//   - 비차단: 호출부가 Task { } 로 감싸 UI 지연 없이 background 실행.
//   - 수동 우선순위 보호: manualPriority != nil이면 분석 자체를 건너뜀.
//   - 폴백: AFM 미가용(구형 기기 등) 시 FoundationModelsEngine이 자동으로
//     HeuristicEngine으로 폴백 → 즉시·결정론적 점수 부여.
//
// ⚠️ 전체 상대 재정렬은 기존 "AI 정리" 버튼(runPrioritize)이 담당.
//    이 서비스는 단일 항목 삽입 시 "약한(weak) 정렬"만 수행한다.

@MainActor
enum QuickSortService {

    /// 수동 추가된 단일 TODO를 온디바이스 AFM으로 즉시 분석하고 약한 우선순위 점수를 부여한다.
    ///
    /// - Parameters:
    ///   - todo: 방금 삽입된 Todo 인스턴스.
    ///   - persona: 현재 페르소나 컨텍스트 (가중 키워드·설명 포함).
    static func analyzeOnAdd(_ todo: Todo, persona: PersonaContext) async {
        // 수동 우선순위 설정 시 자동 분석 생략 (사용자 의도 존중)
        guard todo.manualPriority == nil else { return }

        // 항상 온디바이스: FoundationModelsEngine(AFM ANE) → Heuristic 폴백 체인
        let engine  = FoundationModelsEngine()
        let results = (try? await engine.prioritize(todos: [todo], events: [], persona: persona)) ?? []

        guard let result = results.first else { return }

        // Todo.apply()로 공통 적용 (runPrioritize와 동일 경로)
        todo.apply(result)
    }
}
