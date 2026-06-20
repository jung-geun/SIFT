import Foundation

// MARK: - Foundation Models Service (WWDC 2026)
//
// 사용 조건:
//   1. Xcode > 프로젝트 타깃 > Frameworks, Libraries, and Embedded Content →
//      FoundationModels.framework 추가 (File → Add Frameworks → FoundationModels).
//   2. 실기기에서 Apple Intelligence 활성화 (iPhone 15 Pro+ / M-시리즈 Mac).
//   3. FoundationModelsService.isAvailable == true 확인 후 사용.
//
// 장점:
//   - Neural Engine(ANE) 실행 → GPU 백그라운드 제약·메모리 경고 취소 클래스 자체가 없음.
//   - Guided Generation(@Generable) → 우선순위 점수 0% 버그 구조적 해소.
//   - 모델 다운로드 불필요. 시스템 관리 모델.
//
// ⚠️ 프라이버시 불변식: 모든 추론 온디바이스 완결. 네트워크 미전송.
//    페르소나·우선순위 프롬프트에 이메일 본문 미포함 (메타데이터·통계만).

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Guided Generation Types

/// 페르소나 생성·개선 출력 구조체.
/// @Generable → LanguageModelSession.respond(to:generating:) 으로 타입 안전 생성.
@Generable
struct FMPersonaOutput {
    @Guide(description: "2~4문장 한국어 페르소나. 업무 가치관·시간대 선호·처리 스타일·카테고리 우선순위 포함.")
    var personaText: String

    @Guide(description: "2~3개의 발견된 행동 패턴 인사이트. 각 항목은 한 문장 한국어.")
    var insights: [String]
}

/// 단일 할 일 우선순위 랭킹.
@Generable
struct FMPriorityRanking {
    // E-2: UUID 대신 정수 번호 — 모델의 UUID 변형으로 인한 조용한 누락 버그 해소.
    @Guide(description: "할 일 번호 (그대로 복사, 정수 문자열)")
    var todoID: String

    @Guide(description: "우선순위 점수. 0.01(가장 낮음)~1.0(최우선). 절대 0으로 두지 말 것 — 마감 없어도 0.2 이상.")
    var score: Double

    @Guide(description: "40자 이내 한국어 우선순위 이유")
    var reason: String

    @Guide(description: "세부 설명. 빈 문자열 가능.")
    var detail: String

    @Guide(description: "오늘 마감·임박·중요 키워드 있으면 true")
    var needsNotification: Bool

    @Guide(description: "처리 추천 시각 ISO8601 문자열. 불확실하면 빈 문자열.")
    var recommendedISO: String

    @Guide(description: "사용자 페르소나에 부합하면 true")
    var personaFit: Bool
}

/// 우선순위 랭킹 목록 래퍼.
@Generable
struct FMPriorityRankingList {
    var rankings: [FMPriorityRanking]
}

/// 행동 패턴 인사이트 재작성 출력 (B: 포그라운드 패턴 분석).
/// summary는 휴리스틱 값 유지 — FM은 insights 배열만 재작성.
@Generable
struct FMPatternOutput {
    @Guide(description: "2~4개의 사용자 행동 패턴 인사이트. 각 항목은 한 문장 한국어. 통계 요약을 사용자 친화적 언어로 재표현.")
    var insights: [String]
}

/// 이메일 마감 추출 출력 (C: AFM 강제 메일 분석).
/// OnDeviceLLMEmailEngine.parseExtraction의 EmailExtraction 필드와 1:1 대응.
@Generable
struct FMEmailOutput {
    @Guide(description: "마감일 ISO8601 문자열(예: 2026-12-31T23:59:00). 명시적 마감이 없으면 빈 문자열. 추측 금지.")
    var dueDateISO: String

    @Guide(description: "종일 일정 여부. 시간 없이 날짜만 지정된 경우 true.")
    var isAllDay: Bool

    @Guide(description: "발신자 표시 이름. 없으면 빈 문자열.")
    var sender: String

    @Guide(description: "발신자 이메일 주소. 없으면 빈 문자열.")
    var senderEmail: String

    @Guide(description: "마감 키워드 점수. 마감·기한·deadline·due·expires 있으면 1, 없으면 0.")
    var keywordScore: Int

    @Guide(description: "마감 관련 핵심 문장 또는 한국어 요약 1-2문장. 없으면 빈 문자열.")
    var deadlineSentence: String

    @Guide(description: "이메일 핵심 내용 메모. 1-3줄 한국어. 없으면 빈 문자열.")
    var notes: String
}

// MARK: - Service

/// WWDC 2026 Foundation Models(`SystemLanguageModel`) 기반 서비스.
/// iOS 26.0+, ANE 실행, Guided Generation으로 타입 안전 출력.
///
/// ⚠️ API 호환성: `session.respond(to:generating:)` 반환형이 T 직접인지
///    GeneratedContent<T>인지 프레임워크 버전에 따라 다를 수 있음.
///    크래시 시 `.content` accessor 추가/제거 조정.
@available(iOS 26.0, *)
struct FoundationModelsService {

    // E-1: 배치 크기 — FM 컨텍스트 창(~4096 토큰, 입력+출력 합산)에 맞게 분할.
    // 배치당 transcript 추정: 입력 ~1100 + 출력 ~560 = ~1700 토큰 (4096 대비 충분한 여유).
    private let fmBatchSize = 8

    // E-4: 가변 길이 입력 방어 캡 (현재 유한하나 페르소나·메모리 누적 시 미래 보호).
    private let inputCharCap = 600

    /// Apple Intelligence가 현재 기기에서 사용 가능한지 여부.
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: - 페르소나 생성·개선

    /// 온디바이스 Foundation Models로 페르소나를 생성하거나 점진적으로 개선한다.
    ///
    /// - Parameters:
    ///   - existingPersona: 기존 페르소나 텍스트 (첫 생성이면 빈 문자열)
    ///   - todos: 분석할 할 일 목록 (메타데이터만 사용, 본문 미포함)
    /// - Returns: (personaText, insights) 튜플
    func generatePersona(
        existingPersona: String,
        todos: [Todo]
    ) async throws -> (personaText: String, insights: [String]) {
        let instructions = buildPersonaInstructions(existingPersona: existingPersona)
        let prompt       = buildPersonaPrompt(existingPersona: existingPersona, todos: todos)

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: FMPersonaOutput.self)
        let output   = response.content

        let text     = output.personaText.trimmingCharacters(in: .whitespaces)
        let insights = output.insights.filter { !$0.isEmpty }
        return (text.isEmpty ? existingPersona : text, insights)
    }

    // MARK: - 우선순위 랭킹 (Guided Generation + 배칭)

    /// Guided Generation으로 할 일 우선순위를 산출한다.
    ///
    /// E-1: FM 컨텍스트 창 초과 방지를 위해 최대 fmBatchSize(8)개씩 배칭.
    ///   - 배치마다 fresh LanguageModelSession → 호출 간 transcript 누적 없음.
    ///   - score는 절대값(마감·중요도 기반)이고 todos는 dueDate 정렬 후 전달되어
    ///     배치 간 보정 드리프트 미미 → 정렬 목적에 충분.
    /// E-2: UUID 대신 1-based 정수 번호 → 모델 UUID 변형으로 인한 조용한 누락 버그 해소.
    ///
    /// - Parameters:
    ///   - todos: 우선순위 평가 대상 (미완료, 최대 20개 — 호출 전 dueDate 정렬됨)
    ///   - events: 향후 7일 캘린더 이벤트 컨텍스트
    ///   - persona: 사용자 페르소나 컨텍스트
    /// - Returns: PriorityResult 배열
    func rankTodos(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext
    ) async throws -> [PriorityResult] {
        guard !todos.isEmpty else { return [] }

        // E-2: 전역 1-based 정수 인덱스 맵 구성 (UUID 역참조용)
        let indexedTodos: [(idx: Int, todo: Todo)] = todos.enumerated().map { ($0.offset + 1, $0.element) }
        let indexMap: [String: UUID] = Dictionary(
            uniqueKeysWithValues: indexedTodos.map { (String($0.idx), $0.todo.id) }
        )

        // E-1: fmBatchSize 단위로 분할 — 배치당 transcript가 컨텍스트 창 내에 수렴
        let batches: [[(idx: Int, todo: Todo)]] = stride(from: 0, to: indexedTodos.count, by: fmBatchSize).map {
            Array(indexedTodos[$0 ..< min($0 + fmBatchSize, indexedTodos.count)])
        }

        let instructions = buildRankingInstructions(persona: persona)
        let isoParser    = ISO8601DateFormatter()
        var allResults   = [PriorityResult]()

        for batch in batches {
            let prompt   = buildRankingPrompt(indexedBatch: batch, events: events)
            let session  = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: FMPriorityRankingList.self)
            let output   = response.content

            for r in output.rankings {
                // E-2: 정수 번호로 역참조 — 모델이 번호를 에코하면 변형 없이 매핑
                let key = r.todoID.trimmingCharacters(in: .whitespaces)
                guard let uuid = indexMap[key] else { continue }
                let recommendedTime: Date? = r.recommendedISO.isEmpty ? nil : isoParser.date(from: r.recommendedISO)
                allResults.append(PriorityResult(
                    todoID: uuid,
                    score: max(0.01, min(1.0, r.score)),
                    reason: r.reason,
                    detail: r.detail,
                    needsNotification: r.needsNotification,
                    recommendedTime: recommendedTime,
                    personaFit: r.personaFit,
                    engine: .foundationModels   // ANE 실행 — 메모리 경고 없음
                ))
            }
        }

        return allResults
    }

    // MARK: - 행동 패턴 인사이트 재작성 (B: 포그라운드 분석)

    /// 휴리스틱 패턴 요약을 FM이 사용자 친화적 인사이트로 재작성한다.
    /// insights 배열만 반환 — summary·fastTags는 호출 전 heuristic에서 확정됨.
    /// 포그라운드 전용. 백그라운드 BGTask는 MemoryService.analyze()를 직접 호출.
    func generatePatternInsights(summary: String, todos: [Todo]) async throws -> [String] {
        guard !summary.isEmpty else { return [] }

        let instructions = """
당신은 사용자의 할 일 완료 패턴을 분석해 실용적 인사이트를 제공하는 어시스턴트입니다.
통계 데이터를 사용자가 이해하기 쉬운 한국어 문장으로 재표현하세요.
각 인사이트는 한 문장으로, 구체적이고 행동 가능한 조언을 포함하세요.
"""
        let recentTitles = todos.filter { $0.isCompleted }.prefix(10)
            .map { String($0.title.prefix(40)) }.joined(separator: ", ")

        let prompt = """
[통계 요약]
\(String(summary.prefix(inputCharCap)))

\(recentTitles.isEmpty ? "" : "[최근 완료 할 일 예시]\n\(recentTitles)\n")
위 데이터를 바탕으로 사용자 친화적 인사이트 2~4개를 생성해주세요.
"""
        let session  = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: FMPatternOutput.self)
        return response.content.insights.filter { !$0.isEmpty }
    }

    // MARK: - 이메일 마감 추출 (C: AFM 강제)

    /// Apple Foundation Models로 이메일 마감일을 추출한다.
    /// 본문 캡 ~1500자. 온디바이스/PCC 전용 — 외부 미전송 (프라이버시 불변식).
    /// 포그라운드 전용. 백그라운드 BGTask는 OnDeviceDetectorEngine(NSDataDetector) 사용.
    func analyzeEmail(_ msg: GmailMessage, now: Date) async throws -> EmailExtraction? {
        let bodyPreview = String(msg.body.prefix(1500))
        guard !msg.subject.isEmpty else { return nil }

        let instructions = """
당신은 이메일 마감일 분석 전문가입니다.
이메일을 분석해 마감일·발신자·핵심 내용을 추출하세요.
명시적 마감일이 없으면 dueDateISO를 빈 문자열로 두세요.
절대로 추측이나 가정으로 날짜를 만들지 마세요.
"""
        let isoNow = ISO8601DateFormatter().string(from: now)
        let prompt = """
현재 시각: \(isoNow)
발신자: \(msg.from)
제목: \(msg.subject)
\(bodyPreview.isEmpty ? "" : "본문:\n\(bodyPreview)")
"""
        let session  = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: FMEmailOutput.self)
        let output   = response.content

        // 마감일 파싱
        guard !output.dueDateISO.isEmpty else { return nil }
        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        guard let dueDate = isoParser.date(from: output.dueDateISO), dueDate > now else { return nil }

        // 종일 보정
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: dueDate)
        var finalDate = dueDate
        var isAllDay  = output.isAllDay
        if comps.hour == 0 && comps.minute == 0 && (comps.second ?? 0) == 0 {
            isAllDay = true
            var eod = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
            eod.hour = 23; eod.minute = 59
            finalDate = Calendar.current.date(from: eod) ?? dueDate
        }

        let df = DateFormatter()
        df.locale    = Locale(identifier: "ko_KR")
        df.dateStyle = .long
        df.timeStyle = isAllDay ? .none : .short
        var notesLines = ["⏰ \(df.string(from: finalDate))까지"]
        if !output.notes.isEmpty   { notesLines += [output.notes, "(AI 요약)"] }
        if !output.sender.isEmpty  { notesLines += ["", "[발신자] \(output.sender)"] }

        return EmailExtraction(
            dueDate:          finalDate,
            isAllDay:         isAllDay,
            sender:           output.sender,
            senderEmail:      output.senderEmail,
            keywordScore:     output.keywordScore,
            deadlineSentence: output.deadlineSentence,
            notes:            notesLines.joined(separator: "\n")
        )
    }

    // MARK: - Prompt Builders (페르소나)

    private func buildPersonaInstructions(existingPersona: String) -> String {
        var lines = [
            "당신은 할 일 패턴을 분석해 AI 우선순위 페르소나를 생성·개선하는 어시스턴트입니다.",
            "페르소나는 AI가 할 일 우선순위를 결정할 때 참고하는 사용자 가치관 프로필입니다.",
            "반드시 지정된 구조(personaText 2~4문장, insights 2~3개)로만 답하세요."
        ]
        if !existingPersona.isEmpty {
            lines.append("기존 페르소나를 유지하며 새 패턴을 반영해 점진적으로 개선하세요.")
        }
        return lines.joined(separator: "\n")
    }

    private func buildPersonaPrompt(existingPersona: String, todos: [Todo]) -> String {
        var lines: [String] = []

        // E-4: 가변 길이 입력에 방어적 char 캡 적용
        if !existingPersona.isEmpty {
            lines += ["[기존 페르소나]", String(existingPersona.prefix(inputCharCap)), ""]
        }

        let memory = MemoryService.shared.summary
        if !memory.isEmpty { lines += ["[행동 패턴 메모리]", String(memory.prefix(inputCharCap)), ""] }

        let cal   = Calendar.current
        let times = todos.filter { $0.isCompleted }.compactMap { $0.completedAt }
        if !times.isEmpty {
            let byHour = Dictionary(grouping: times) { cal.component(.hour, from: $0) }
            let top = byHour.sorted { $0.value.count > $1.value.count }.prefix(3)
                .map { "\($0.key)시(\($0.value.count)건)" }.joined(separator: ", ")
            lines += ["[완료 시간대 패턴]", top, ""]
        }

        let allTags = todos.flatMap { $0.tags }
        if !allTags.isEmpty {
            let freq = Dictionary(allTags.map { ($0, 1) }, uniquingKeysWith: +)
            let top  = freq.sorted { $0.value > $1.value }.prefix(6)
                .map { "\($0.key)(\($0.value)회)" }.joined(separator: ", ")
            lines += ["[자주 쓰는 태그]", top, ""]
        }

        // E-3: 제목 60자 절단 (이메일 출처 긴 제목이 입력·출력 양쪽을 비대화)
        let done = todos.filter { $0.isCompleted }.prefix(15)
        if !done.isEmpty {
            lines.append("[최근 완료 할 일]")
            lines += done.map { todo in
                let title = String(todo.title.prefix(60))
                return "• \(title)" + (todo.tags.isEmpty ? "" : " [\(todo.tags.joined(separator: ","))]")
            }
            lines.append("")
        }

        let active = todos.filter { !$0.isCompleted }.prefix(20)
        if !active.isEmpty {
            let rf = RelativeDateTimeFormatter(); rf.unitsStyle = .abbreviated
            lines.append("[현재 할 일 (\(todos.filter { !$0.isCompleted }.count)개)]")
            lines += active.map { todo in
                let title = String(todo.title.prefix(60))  // E-3
                var s = "• \(title)"
                if let d = todo.dueDate { s += " [마감: \(rf.localizedString(for: d, relativeTo: Date()))]" }
                if !todo.tags.isEmpty   { s += " [\(todo.tags.joined(separator: ","))]" }
                return s
            }
            lines.append("")
        }

        lines.append("위 데이터를 바탕으로 페르소나를 \(existingPersona.isEmpty ? "생성" : "개선")해주세요.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt Builders (우선순위)

    private func buildRankingInstructions(persona: PersonaContext) -> String {
        var lines = [
            "당신은 개인 스케줄 비서입니다. 할 일 목록의 우선순위를 분석하세요.",
            "score: 0.01~1.0. 마감 없어도 중요도(교수·관계·제출·미팅)에 따라 0.3 이상 부여.",
            "페르소나 부합 시 score 높게, personaFit: true, reason에 '페르소나 관련' 포함.",
            "고정 일정 여부는 '고정(주기)' 표기 항목에만 판단. 직접입력 항목을 '필수·고정·반드시'로 단정 금지.",
            "needsNotification: 오늘 마감·임박·중요 키워드 있으면 true.",
            "recommendedISO: 처리 추천 시각(ISO8601). 불확실하면 빈 문자열."
        ]
        if !persona.types.isEmpty { lines.append("사용자 유형: \(persona.displayNames)") }
        // E-4: 가변 길이 입력 방어 캡
        if !persona.description.isEmpty {
            lines.append("사용자 가치관:\n\(String(persona.description.prefix(inputCharCap)))")
        }
        let memory = MemoryService.shared.summary
        if !memory.isEmpty {
            lines.append("사용자 행동 패턴 (참고):\n\(String(memory.prefix(inputCharCap)))")
        }
        return lines.joined(separator: "\n")
    }

    /// E-1/E-2: 배치 슬라이스(전역 인덱스 포함) + 이벤트로 랭킹 프롬프트 생성.
    /// 제목은 E-3 가드(60자 절단) 적용.
    private func buildRankingPrompt(
        indexedBatch: [(idx: Int, todo: Todo)],
        events: [CalendarService.CalendarEventSummary]
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["현재 시각: \(iso.string(from: Date()))"]
        if !events.isEmpty {
            lines.append("\n[캘린더 이벤트 (향후 7일)]")
            for e in events.prefix(10) { lines.append("• \(e.title) — \(iso.string(from: e.startDate))") }
        }
        lines.append("\n[우선순위 평가 대상 할 일]")
        for (idx, todo) in indexedBatch {
            // E-2: 정수 번호, E-3: 제목 60자 절단
            let title = String(todo.title.prefix(60))
            var ps = ["번호:\(idx)", "제목:\(title)"]
            if let due = todo.dueDate { ps.append("마감:\(iso.string(from: due))") }
            if !todo.tags.isEmpty     { ps.append("태그:\(todo.tags.joined(separator: ","))") }
            let src: String
            switch todo.todoSource {
            case .manual:   src = "직접입력"
            case .email:    src = "이메일"
            case .calendar: src = "캘린더"
            }
            ps.append("출처:\(src)")
            if todo.isFixedSchedule { ps.append("고정(주기)") }
            lines.append("• " + ps.joined(separator: " | "))
        }
        lines.append("\n위 할 일들의 우선순위를 rankings 배열로 반환하세요.")
        return lines.joined(separator: "\n")
    }
}
#endif
