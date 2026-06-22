import Foundation

// MARK: - LLM 날짜/시각 포맷 유틸
//
// LLM 입출력 경계에서 사용하는 모든 날짜/시각을 현지 offset 포함 ISO8601로 통일한다.
// 저장(SwiftData Date)은 변경 없음 — 이 유틸은 직렬화/파싱 레이어만 담당한다.
enum AppDateFormat {

    // MARK: - 직렬화: LLM에 보내는 시각

    /// Date → 현지 offset 포함 ISO8601 문자열 (예: "2026-06-21T21:00:00+09:00")
    ///
    /// LLM이 사용자의 현지 시각을 정확히 인식하도록 항상 offset을 포함한다.
    /// 기존 `ISO8601DateFormatter()` 기본값(GMT, `Z` suffix)을 대체한다.
    static func llmString(from date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    // MARK: - 파싱: LLM 출력 → Date

    /// ISO8601 또는 다중 포맷 문자열 → Date
    ///
    /// - offset 포함: 그대로 파싱 (예: "2026-06-21T21:00:00+09:00")
    /// - offset 없음: 현지(`.current`) 기준으로 해석 — 기존엔 nil이던 케이스를 복구
    /// - 빈 문자열: nil 반환
    static func parseLLMDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // 1) offset 포함 ISO8601 (현지 직렬화 결과 및 표준 형식)
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        if let d = isoFull.date(from: s) { return d }

        // 2) offset 없는 폴백 — 현지 기준으로 해석 (기존 모델 출력 호환)
        let formats: [String] = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Date -> 남은 시간 자연어 설명 (예: "4시간 후 마감", "3일 후 마감")
    static func remainingTimeDescription(for dueDate: Date) -> String {
        let diff = dueDate.timeIntervalSinceNow
        if diff < 0 {
            return "마감 초과"
        }
        let hours = Int(diff / 3600)
        if hours < 1 {
            let minutes = max(1, Int(diff / 60))
            return "\(minutes)분 후 마감"
        } else if hours < 24 {
            return "\(hours)시간 후 마감"
        } else {
            let days = hours / 24
            return "\(days)일 후 마감"
        }
    }
}
