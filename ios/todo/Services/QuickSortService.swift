import Foundation
import SwiftData

// MARK: - 수동 추가 시 약한 AI 정렬 서비스
//
// TODO를 수동으로 추가하는 즉시 해당 항목만 현재 선택된 라우터로 단일 분석해
// 근사 우선순위 점수를 부여한다.
//
// 설계 원칙:
//   - 동일 라우팅 사용: 목록의 "AI 정리"와 같은 provider 선택 / 전송 동의 / 규칙 폴백 정책을 따른다.
//   - 비차단: 호출부가 Task { } 로 감싸 UI 지연 없이 background 실행.
//   - 수동 우선순위 보호: manualPriority != nil이면 분석 자체를 건너뜀.
//   - 폴백: 라우터 전체 실패 시에만 HeuristicEngine으로 즉시·결정론적 점수 부여.
//
// ⚠️ 전체 상대 재정렬은 기존 "AI 정리" 버튼(runPrioritize)이 담당.
//    이 서비스는 단일 항목 삽입 시 "약한(weak) 정렬"만 수행한다.

@MainActor
enum QuickSortService {

    /// 수동 추가된 단일 TODO를 현재 선택된 AI 라우터로 즉시 분석하고 약한 우선순위 점수를 부여한다.
    ///
    /// - Parameters:
    ///   - todo: 방금 삽입된 Todo 인스턴스.
    ///   - persona: 현재 페르소나 컨텍스트 (가중 키워드·설명 포함).
    static func analyzeOnAdd(_ todo: Todo, persona: PersonaContext, context: ModelContext) async {
        // 수동 우선순위 설정 시 자동 분석 생략 (사용자 의도 존중)
        guard todo.manualPriority == nil else { return }
        let todoID = todo.id

        let results: [PriorityResult]
        do {
            results = try await RoutedIntelligenceEngine()
                .prioritize(todos: [todo], events: [], persona: persona)
        } catch is CancellationError {
            return
        } catch {
            let heuristic = try? await HeuristicEngine().prioritize(todos: [todo], events: [], persona: persona)
            results = heuristic?.map {
                var updated = $0
                updated.executionPath = .rules(.providerExecutionFailed)
                updated.fallbackReason = RuleFallbackReason.providerExecutionFailed.rawValue
                return updated
            } ?? []
        }

        guard let result = results.first else { return }
        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate { $0.id == todoID }
        )
        descriptor.fetchLimit = 1
        guard let liveTodo = try? context.fetch(descriptor).first,
              liveTodo.manualPriority == nil else {
            return
        }

        // Todo.apply()로 공통 적용하고 실제 산출 엔진을 telemetry에 보존한다.
        let previousScore = liveTodo.computedPriorityScore
        liveTodo.apply(result)
        TaskBehaviorRecorder.recordComputedPriorityChange(
            of: liveTodo,
            from: previousScore,
            to: liveTodo.computedPriorityScore,
            actor: result.engine == .heuristic ? .system : .artificialIntelligence,
            in: context
        )
    }
}
