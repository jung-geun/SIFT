import Foundation

// MARK: - 4축 스코어 구조체

/// timesorter-v9 호환 4개 개별 축 점수. 각 0 ~ 10.
/// total_score는 ScheduleScorer.total()로 수동 계산 (단일 점수 통합 회피).
struct AxisScores: Sendable, Equatable {
    /// 마감 임박도: 10 = 마감 초과·즉시, 0 = 마감 없음/매우 여유
    var deadlineProximity: Double
    /// 긴급도: 마감근접 + 출처/키워드 신호 (즉시성 ≠ 잔여시간)
    var urgency: Double
    /// 중요도: 태그·페르소나·fastTags 기반
    var importance: Double
    /// 체이닝: 9 = 비최종 체인 단계, 6 = 최종 체인 단계, 2 = 독립 태스크
    var chaining: Double
}

// MARK: - 가중치

/// 데이터셋(timesorter-v9) 기본 가중치 + 사용자 패턴 기반 자동 조정.
/// 기본값: urgency 0.30 / deadlineProximity 0.25 / importance 0.30 / chaining 0.15
struct ScheduleWeights: Sendable {
    var urgency:           Double = 0.30
    var deadlineProximity: Double = 0.25
    var importance:        Double = 0.30
    var chaining:          Double = 0.15

    /// 사용자 패턴 기반 자동 조정.
    /// overdueRate > 0.30 이면 deadline/urgency 가중치를 높이고 importance/chaining을 낮춤.
    /// 최대 이동 폭 ±0.15, 각 축 최소 0.05, 합 = 1.0 보장.
    static func adaptive(from memory: MemoryService = .shared) -> ScheduleWeights {
        var w = ScheduleWeights()
        let excess = max(0, memory.overdueRate - 0.30)   // 0.30 초과분
        let shift  = min(0.15, excess * 0.30)            // 최대 ±0.15
        w.deadlineProximity += shift * 0.60
        w.urgency           += shift * 0.40
        w.importance        -= shift * 0.60
        w.chaining          -= shift * 0.40
        return w.normalized()
    }

    /// 각 축 ≥ 0.05 클램프 후 합 = 1.0 정규화
    func normalized() -> ScheduleWeights {
        var w     = self
        let floor = 0.05
        w.urgency           = max(floor, w.urgency)
        w.deadlineProximity = max(floor, w.deadlineProximity)
        w.importance        = max(floor, w.importance)
        w.chaining          = max(floor, w.chaining)
        let sum = w.urgency + w.deadlineProximity + w.importance + w.chaining
        guard sum > 0 else { return w }
        w.urgency           /= sum
        w.deadlineProximity /= sum
        w.importance        /= sum
        w.chaining          /= sum
        return w
    }
}

// MARK: - 스코어 계산기

/// 4축 → total_score 변환. 데이터셋 공식과 동일.
/// total = w.urgency·urgency + w.deadline·deadline + w.importance·importance + w.chaining·chaining
enum ScheduleScorer {

    /// 0 ~ 10 범위 total_score (소수 2자리, 데이터셋 공식 기준)
    static func total(_ axes: AxisScores, weights: ScheduleWeights = .init()) -> Double {
        let raw = weights.urgency           * axes.urgency
                + weights.deadlineProximity * axes.deadlineProximity
                + weights.importance        * axes.importance
                + weights.chaining          * axes.chaining
        return (raw * 100).rounded() / 100
    }

    /// PriorityResult.score (0 ~ 1) 스케일로 변환
    static func normalizedScore(_ axes: AxisScores, weights: ScheduleWeights = .init()) -> Double {
        min(1.0, total(axes, weights: weights) / 10.0)
    }
}
