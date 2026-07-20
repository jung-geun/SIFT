import Foundation

// MARK: - Email Extraction Result

struct EmailExtraction {
    let dueDate: Date
    /// true = 날짜만 감지됨(시각 없음), dueDate는 23:59로 보정됨
    let isAllDay: Bool
    /// From 헤더에서 파싱한 발신자 표시명
    let sender: String
    /// From 헤더에서 파싱한 발신자 이메일 주소 (학습 억제 키)
    let senderEmail: String
    /// 마감 키워드 근접 점수 (0 = 키워드 없음, 1+ = 키워드 있음)
    let keywordScore: Int
    /// 마감일 주변 컨텍스트 문장 (온디바이스 추출, AI 요약 아님)
    let deadlineSentence: String
    /// 할 일 notes 필드에 채울 텍스트
    let notes: String
}

// MARK: - On-Device Email Content Analyzer

/// Gmail 메시지를 온디바이스에서 분석해 마감일을 감지하는 분석기.
///
/// NSDataDetector(.date) 기반 — 네트워크·AFM 없이 완전 로컬.
/// 프라이버시 규칙("메일 본문을 외부 API로 보내지 않음")을 그대로 지킨다.
///
/// - 마감일이 감지되지 않으면 nil 반환 → 할 일 미생성
/// - keywordScore 0 = 날짜는 있지만 마감 문맥 없음 → 참고함(triage = review) 후보
/// - keywordScore ≥ 1 = 마감 문맥 확인됨 → 할 일(triage = todo) 후보
struct EmailContentAnalyzer {

    // MARK: - Configuration

    /// 날짜 매치 주변에서 마감 의미를 부여하는 키워드
    private let deadlineKeywords = [
        // 한국어 마감
        "까지", "마감", "기한", "유효기간", "만료", "종료",
        "중단", "지원 종료", "서비스 종료", "폐지",
        // 영어 마감
        "expires", "expire", "expiry", "deadline", "due", "by ",
        "shut down", "shutdown", "deprecat", "discontinu"
    ]
    /// 키워드 근접 판단 창 (날짜 매치 전후 N 문자)
    private let contextWindow = 120
    /// 감지 허용 최대 미래 창 (약 370일)
    private let maxLookAheadDays: Double = 370

    // MARK: - Entry Point

    /// 메시지를 분석해 마감일 + 부가 정보를 추출.
    /// 마감일을 찾지 못하면 nil을 반환한다.
    func analyze(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage = .current
    ) -> EmailExtraction? {
        let maxDate = now.addingTimeInterval(maxLookAheadDays * 24 * 3600)
        // 제목 + 본문을 합쳐 분석 — 제목에 마감일 언급이 많음
        let fullText = msg.subject + "\n" + msg.body

        // 1. 날짜 후보 수집
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return nil }

        let nsRange = NSRange(fullText.startIndex..., in: fullText)
        let matches = detector.matches(in: fullText, options: [], range: nsRange)

        // 2. 미래 날짜만 필터 + 키워드 근접 점수 부여
        var candidates: [(date: Date, score: Int, context: String, matchRange: Range<String.Index>, timeZone: TimeZone?, sourceText: String)] = []
        for match in matches {
            var score = 0
            var contextStr = ""
            var swiftMatchRange: Range<String.Index>?
            var sourceText = ""

            if let swiftRange = Range(match.range, in: fullText) {
                swiftMatchRange = swiftRange
                sourceText = sourceTextForDateMatch(in: fullText, matchRange: swiftRange)

                // 매치 주변 contextWindow 자 범위 추출
                let distToStart = fullText.distance(from: fullText.startIndex, to: swiftRange.lowerBound)
                let distToEnd   = fullText.distance(from: swiftRange.upperBound, to: fullText.endIndex)
                let windowStart = fullText.index(
                    swiftRange.lowerBound,
                    offsetBy: -min(contextWindow, distToStart),
                    limitedBy: fullText.startIndex
                ) ?? fullText.startIndex
                let windowEnd   = fullText.index(
                    swiftRange.upperBound,
                    offsetBy: min(contextWindow, distToEnd),
                    limitedBy: fullText.endIndex
                ) ?? fullText.endIndex
                contextStr = String(fullText[windowStart..<windowEnd])
                let contextLower = contextStr.lowercased()
                for kw in deadlineKeywords where contextLower.contains(kw) {
                    score += 1
                }
            }

            let parsedDate = AppDateFormat.parseMailDate(sourceText)
            guard let date = parsedDate ?? match.date else { continue }
            let timeZone = parsedDate != nil
                ? AppDateFormat.sourceTimeZone(in: sourceText)
                : match.timeZone

            // (a) 미래만, (b) ~1년 이내 — 과거 날짜·전화번호·"since YYYY" 노이즈 제거
            guard date > now, date < maxDate else { continue }

            candidates.append((
                date: date,
                score: score,
                context: contextStr,
                matchRange: swiftMatchRange ?? fullText.startIndex..<fullText.startIndex,
                timeZone: timeZone,
                sourceText: sourceText
            ))
        }

        guard !candidates.isEmpty else { return nil }

        // 4. 최선 후보 선택: 점수 높은 것 우선 → 동점이면 가장 이른 날짜
        candidates.sort { a, b in
            a.score != b.score ? a.score > b.score : a.date < b.date
        }
        let best = candidates[0]

        // 5. 날짜만(시각 없음) 감지 → 그날 23:59 로컬/원문 시간대로 보정
        //    안 그러면 "6월 30일까지" 메일이 6월 30일 00:00에 이미 초과 표시됨
        var calendar = Calendar.current
        if let timeZone = best.timeZone {
            calendar.timeZone = timeZone
        }
        let normalizedDeadline = AppDateFormat.normalizedAllDayDeadline(best.date, calendar: calendar)
        let finalDate = normalizedDeadline.date
        let isAllDay = normalizedDeadline.isAllDay

        // 6. 발신자 파싱
        let sender      = parseSender(from: msg.from)
        let senderEmail = parseSenderEmail(from: msg.from)

        // 7. 마감일 주변 추출 문장 — 컨텍스트 윈도우에서 가장 관련 있는 줄 추출
        let deadlineSentence = extractDeadlineSentence(from: best.context, date: finalDate)

        // 8. notes 구성
        let notes = buildNotes(
            sender: sender,
            snippet: msg.snippet,
            date: finalDate,
            isAllDay: isAllDay,
            deadlineSentence: deadlineSentence,
            language: language
        )

        return EmailExtraction(
            dueDate: finalDate,
            isAllDay: isAllDay,
            sender: sender,
            senderEmail: senderEmail,
            keywordScore: best.score,
            deadlineSentence: deadlineSentence,
            notes: notes
        )
    }

    private func sourceTextForDateMatch(in text: String, matchRange: Range<String.Index>) -> String {
        let matchText = String(text[matchRange])
        let remaining = text.distance(from: matchRange.upperBound, to: text.endIndex)
        let scanEnd = text.index(
            matchRange.upperBound,
            offsetBy: min(16, remaining),
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let trailing = String(text[matchRange.upperBound..<scanEnd])
        guard let zoneToken = trailingZoneToken(in: trailing) else {
            return matchText
        }
        return matchText + " " + zoneToken
    }

    private func trailingZoneToken(in text: String) -> String? {
        let pattern = #"(?i)^\s*(Z|UTC|GMT)([+-]\d{1,2}(?::?\d{2})?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let tokenRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let matchEndOffset = match.range.location + match.range.length
        if matchEndOffset < (text as NSString).length {
            let matchEnd = String.Index(utf16Offset: matchEndOffset, in: text)
            if matchEnd < text.endIndex,
               let scalar = String(text[matchEnd]).unicodeScalars.first {
                let value = scalar.value
                let isASCIIAlphanumeric = (48...57).contains(value)
                    || (65...90).contains(value)
                    || (97...122).contains(value)
                if isASCIIAlphanumeric {
                    return nil
                }
            }
        }

        var token = String(text[tokenRange]).uppercased()
        if match.range(at: 2).location != NSNotFound,
           let offsetRange = Range(match.range(at: 2), in: text) {
            token += String(text[offsetRange])
        }
        return token
    }

    // MARK: - Sender Parsing

    /// "표시명" <email@host>  →  표시명
    /// 표시명 <email@host>    →  표시명
    /// email@host             →  로컬파트(@ 앞)
    func parseSender(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let ltIdx = trimmed.firstIndex(of: "<") {
            let display = String(trimmed[..<ltIdx])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespaces)
            if !display.isEmpty { return display }
        }
        if trimmed.contains("@") {
            return String(trimmed.split(separator: "@").first ?? Substring(trimmed))
        }
        return trimmed
    }

    /// "표시명" <email@host> 또는 email@host → email@host (학습 억제 키)
    func parseSenderEmail(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        // <...> 안에서 추출
        if let ltIdx = trimmed.firstIndex(of: "<"),
           let gtIdx = trimmed.firstIndex(of: ">"),
           ltIdx < gtIdx {
            let addr = String(trimmed[trimmed.index(after: ltIdx)..<gtIdx])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if addr.contains("@") { return addr }
        }
        // <> 없는 순수 이메일 주소
        let candidate = trimmed.lowercased()
        if candidate.contains("@") { return candidate }
        return ""
    }

    // MARK: - Deadline Sentence Extractor

    /// 마감일이 포함된 컨텍스트 윈도우에서 가장 대표적인 줄(문장)을 추출.
    /// 온디바이스 추출이므로 AI 요약이 아님을 주석에 명시.
    private func extractDeadlineSentence(from context: String, date: Date) -> String {
        guard !context.isEmpty else { return "" }
        // 줄 단위로 분리 후 날짜와 가장 가까운 줄 우선 반환
        let lines = context
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 날짜 detector로 날짜 포함 줄 탐색
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else {
            return String(context.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if detector.firstMatch(in: line, range: range) != nil {
                return String(line.prefix(120))
            }
        }
        // 날짜 포함 줄 없으면 컨텍스트 앞부분
        return String(context.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Notes Builder

    /// 마감 추출 문장(lead) + 발신자 + 메일 미리보기(snippet)를 조합해 notes 텍스트 생성.
    /// ⚠️ deadlineSentence는 본문에서 날짜 주변을 추출한 것(온디바이스) — AI 요약 아님.
    private func buildNotes(
        sender: String,
        snippet: String,
        date: Date,
        isAllDay: Bool,
        deadlineSentence: String,
        language: AppLanguage
    ) -> String {
        let dateStr = AppDateFormat.deadlineString(
            from: date,
            isAllDay: isAllDay,
            language: language
        )

        var lines: [String] = []

        lines.append(
            {
                let defaultValue = language == .english
                    ? "Due by \(dateStr)"
                    : "⏰ \(dateStr)까지"
                let localized = AppLanguage.localized(
                    "mail.deadline",
                    defaultValue: defaultValue,
                    language: language,
                    comment: "Detected email deadline"
                )
                return localized == defaultValue
                    ? localized
                    : String(format: localized, locale: language.locale, dateStr)
            }()
        )
        if !deadlineSentence.isEmpty {
            lines.append(deadlineSentence)
            lines.append(
                AppLanguage.localized(
                    "mail.bodyExcerptDisclaimer",
                    defaultValue: language == .english
                        ? "(Body excerpt — not an AI summary)"
                        : "(본문 발췌 — AI 요약 아님)",
                    language: language,
                    comment: "Email body excerpt disclaimer"
                )
            )
        }
        lines.append("")

        if !sender.isEmpty {
            lines.append(
                {
                    let defaultValue = language == .english
                        ? "[Sender] \(sender)"
                        : "[발신자] \(sender)"
                    let localized = AppLanguage.localized(
                        "mail.sender",
                        defaultValue: defaultValue,
                        language: language,
                        comment: "Email sender label"
                    )
                    return localized == defaultValue
                        ? localized
                        : String(format: localized, locale: language.locale, sender)
                }()
            )
            lines.append("")
        }

        if !snippet.isEmpty {
            lines.append(snippet)
        }

        return lines.joined(separator: "\n")
    }
}
