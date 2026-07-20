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

    /// 이메일/모델 경계의 마감 문자열 → Date.
    ///
    /// ISO8601은 그대로 처리하고, 메일 본문에서 흔한 `UTC+9`, `GMT+09:00`, trailing `Z`
    /// 표현은 ISO8601 offset으로 정규화한 뒤 재파싱한다. offset이 없는 문자열은 기존
    /// `parseLLMDate`와 동일하게 기기 현지 시간으로 해석한다.
    static func parseMailDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = parseLLMDate(s) { return d }
        guard let normalized = normalizedMailDateString(s) else { return nil }
        return parseLLMDate(normalized)
    }

    /// 원문 문자열 안의 명시적 메일 시간대(`Z`, `UTC`, `UTC+9`, `GMT-04:00` 등)를 고정 offset으로 반환.
    static func sourceTimeZone(in string: String) -> TimeZone? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let numericOffsetPattern = #"([+-]\d{2}:?\d{2})\s*$"#
        if let regex = try? NSRegularExpression(pattern: numericOffsetPattern),
           let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let offsetRange = Range(match.range(at: 1), in: s),
           let seconds = secondsFromZoneOffset(String(s[offsetRange])) {
            return TimeZone(secondsFromGMT: seconds)
        }

        let pattern = #"(?i)(Z|UTC|GMT)([+-]\d{1,2}(?::?\d{2})?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        let matches = regex.matches(in: s, range: range)
        guard let match = matches.last,
              let tokenRange = Range(match.range(at: 1), in: s) else {
            return nil
        }

        let token = String(s[tokenRange]).uppercased()
        let offsetText: String?
        if match.range(at: 2).location != NSNotFound,
           let offsetRange = Range(match.range(at: 2), in: s) {
            offsetText = String(s[offsetRange])
        } else {
            offsetText = nil
        }

        if token == "Z" || offsetText == nil {
            return TimeZone(secondsFromGMT: 0)
        }

        guard let seconds = secondsFromZoneOffset(offsetText!) else { return nil }
        return TimeZone(secondsFromGMT: seconds)
    }

    /// 날짜-only/자정 보정 시 source 문자열에 명시된 시간대를 적용하는 Calendar.
    static func sourceCalendar(for string: String, fallback: Calendar = .current) -> Calendar {
        var calendar = fallback
        if let timeZone = sourceTimeZone(in: string) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    /// 날짜만 감지되어 자정으로 들어온 마감을 해당 날짜의 23:59로 보정한다.
    static func normalizedAllDayDeadline(_ date: Date, calendar: Calendar = .current) -> (date: Date, isAllDay: Bool) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let isMidnight = components.hour == 0 && components.minute == 0 && (components.second ?? 0) == 0
        guard isMidnight else {
            return (date, false)
        }

        var endOfDay = calendar.dateComponents([.year, .month, .day], from: date)
        endOfDay.hour = 23
        endOfDay.minute = 59
        endOfDay.second = 0
        return (calendar.date(from: endOfDay) ?? date, true)
    }

    static func deadlineString(
        from date: Date,
        isAllDay: Bool,
        language: AppLanguage = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .long
        formatter.timeStyle = isAllDay ? .none : .short
        return formatter.string(from: date)
    }

    private static func localized(
        _ key: String,
        korean: String,
        english: String,
        language: AppLanguage
    ) -> String {
        language == .english ? english : korean
    }

    private static func normalizedMailDateString(_ string: String) -> String? {
        let pattern = #"(?i)^\s*(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})(?::(\d{2}))?\s*(Z|UTC|GMT)([+-]\d{1,2}(?::?\d{2})?)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: nsRange),
              let dateRange = Range(match.range(at: 1), in: string),
              let timeRange = Range(match.range(at: 2), in: string),
              let zoneRange = Range(match.range(at: 4), in: string) else {
            return nil
        }

        let date = String(string[dateRange])
        let time = String(string[timeRange])
        let seconds: String
        if match.range(at: 3).location != NSNotFound,
           let secondsRange = Range(match.range(at: 3), in: string) {
            seconds = String(string[secondsRange])
        } else {
            seconds = "00"
        }

        let zoneToken = String(string[zoneRange]).uppercased()
        let offset: String
        if zoneToken == "Z" {
            offset = "+00:00"
        } else if match.range(at: 5).location != NSNotFound,
                  let offsetRange = Range(match.range(at: 5), in: string),
                  let normalized = normalizedZoneOffset(String(string[offsetRange])) {
            offset = normalized
        } else {
            offset = "+00:00"
        }

        return "\(date)T\(time):\(seconds)\(offset)"
    }

    private static func normalizedZoneOffset(_ offset: String) -> String? {
        guard let seconds = secondsFromZoneOffset(offset) else { return nil }
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private static func secondsFromZoneOffset(_ offset: String) -> Int? {
        guard let signCharacter = offset.first,
              signCharacter == "+" || signCharacter == "-" else {
            return nil
        }

        let sign = signCharacter == "-" ? -1 : 1
        let body = String(offset.dropFirst())
        let hourText: String
        let minuteText: String
        if let colon = body.firstIndex(of: ":") {
            hourText = String(body[..<colon])
            minuteText = String(body[body.index(after: colon)...])
        } else if body.count > 2 {
            let split = body.index(body.endIndex, offsetBy: -2)
            hourText = String(body[..<split])
            minuteText = String(body[split...])
        } else {
            hourText = body
            minuteText = "0"
        }

        guard let hours = Int(hourText),
              let minutes = Int(minuteText),
              (0...23).contains(hours),
              (0...59).contains(minutes) else {
            return nil
        }

        return sign * ((hours * 3600) + (minutes * 60))
    }

    /// Date -> 남은 시간 자연어 설명 (예: "4시간 후 마감", "3일 후 마감")
    static func remainingTimeDescription(
        for dueDate: Date,
        now: Date = Date(),
        language: AppLanguage = .current
    ) -> String {
        let diff = dueDate.timeIntervalSince(now)
        if diff < 0 {
            return localized(
                "date.deadline.overdue",
                korean: "마감 초과",
                english: "Overdue",
                language: language
            )
        }
        let hours = Int(diff / 3600)
        if hours < 1 {
            let minutes = max(1, Int(diff / 60))
            return AppLanguage.localizedCount(
                "date.deadline.minutes",
                count: minutes,
                defaultValue: language == .english
                    ? (minutes == 1 ? "Due in %lld minute" : "Due in %lld minutes")
                    : "%lld분 후 마감",
                language: language,
                comment: "Relative deadline in minutes"
            )
        } else if hours < 24 {
            return AppLanguage.localizedCount(
                "date.deadline.hours",
                count: hours,
                defaultValue: language == .english
                    ? (hours == 1 ? "Due in %lld hour" : "Due in %lld hours")
                    : "%lld시간 후 마감",
                language: language,
                comment: "Relative deadline in hours"
            )
        } else {
            let days = hours / 24
            return AppLanguage.localizedCount(
                "date.deadline.days",
                count: days,
                defaultValue: language == .english
                    ? (days == 1 ? "Due in %lld day" : "Due in %lld days")
                    : "%lld일 후 마감",
                language: language,
                comment: "Relative deadline in days"
            )
        }
    }
}
