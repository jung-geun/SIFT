import Foundation
import SwiftData

// MARK: - Enums

/// 할 일의 출처 — v2 이메일/캘린더 자동 추출에 대비한 enum
enum TodoSource: String, Codable, Sendable {
    case manual   = "manual"
    case email    = "email"
    case calendar = "calendar"
    case meeting  = "meeting"
}

/// 캘린더 이벤트의 소유·생성 경로. 이벤트 URL 마커와 함께 저장해 재설치 후에도
/// 외부 캘린더 import와 SIFT가 만든 일정을 구분한다.
enum CalendarEventOrigin: String, Codable, Sendable, Equatable {
    case externalCalendar = "externalCalendar"
    case siftManual = "siftManual"
    case siftEmail = "siftEmail"
    case siftMeeting = "siftMeeting"
    case siftRecommendation = "siftRecommendation"

    static func inferred(from todo: Todo) -> CalendarEventOrigin {
        // AI가 imported calendar Todo를 분석했더라도, 외부 이벤트의 소유권을
        // SIFT 추천 일정으로 바꾸면 안 된다.
        if todo.todoSource == .calendar {
            return .externalCalendar
        }
        if todo.aiRecommendedTime != nil {
            return .siftRecommendation
        }
        switch todo.todoSource {
        case .calendar: return .externalCalendar
        case .email: return .siftEmail
        case .meeting: return .siftMeeting
        case .manual: return .siftManual
        }
    }

    var isSiftManaged: Bool {
        self != .externalCalendar
    }
}

/// 이메일 메일 triage 결과 — 메인 할 일 vs 참고함
enum TodoTriage: String, Codable, Sendable {
    case todo   = "todo"    // 메인 할 일 목록에 표시
    case review = "review"  // 참고함 — 마감은 있으나 진짜 할 일인지 불확실
}

/// 수동 우선순위 단계 (1=낮음 … 5=최우선)
enum TodoPriority: Int, Codable, CaseIterable, Sendable {
    case low      = 1
    case medium   = 2
    case high     = 3
    case urgent   = 4
    case critical = 5

    var label: String {
        displayName(language: .current)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .low:      return language == .english ? "Low" : "낮음"
        case .medium:   return language == .english ? "Medium" : "보통"
        case .high:     return language == .english ? "High" : "높음"
        case .urgent:   return language == .english ? "Urgent" : "긴급"
        case .critical: return language == .english ? "Critical" : "최우선"
        }
    }

    var systemColor: String {
        switch self {
        case .low:      "gray"
        case .medium:   "blue"
        case .high:     "orange"
        case .urgent:   "red"
        case .critical: "purple"
        }
    }
}

// MARK: - Todo Model

/// 핵심 할 일 모델.
///
/// CloudKit private DB 동기화 제약 준수:
/// - 모든 비옵셔널 저장 프로퍼티에 기본값 부여
/// - @Attribute(.unique) 사용 금지 (UUID 기본값으로 고유성 보장)
/// - 관계(relationship)는 옵셔널로 선언
@Model
final class Todo {

    // MARK: - Identity
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: - Scheduling
    var dueDate: Date?
    /// 일정의 시작 시각. 시각이 있는 캘린더 일정에서 import되거나 상세 화면에서 지정된다.
    /// nil = 시작 시각 없음(마감만 있는 기존 할 일). dueDate가 nil이면 항상 nil이다.
    var startDate: Date?
    var isCompleted: Bool = false
    /// v3 메모리: 완료 시각 패턴 분석에 활용
    var completedAt: Date?

    // MARK: - Priority (수동 / 자동 분리)

    /// 사용자가 직접 설정한 우선순위 (nil = 미지정). TodoPriority.rawValue 사용.
    var manualPriority: Int?
    /// IntelligenceService가 산출하는 0.0~1.0 자동 우선순위 점수
    var computedPriorityScore: Double = 0.0
    /// FM이 제공한 한 줄 우선순위 근거 (UI에 표시)
    var priorityReason: String = ""

    // MARK: - Reminders

    /// 만료(dueDate) 기준 상대 오프셋(초, 음수 = before).
    /// 예: [-3600.0, -21600.0, -86400.0] = 1시간·6시간·하루 전
    var reminderOffsets: [Double] = []

    /// timesorter-v9 ScheduleInput용 예상 소요 시간(분). 기본 30분. CloudKit-safe(비옵셔널+기본값).
    var estimatedDurationMinutes: Int = 30

    // MARK: - Source Tracking

    /// TodoSource.rawValue — CloudKit String 호환
    var source: String = TodoSource.manual.rawValue
    /// 출처 원본 참조: v2 Gmail messageId, EKEvent.eventIdentifier 등
    var sourceRef: String = ""
    /// 발신자 표시명 (이메일 출처일 때 From 헤더에서 파싱)
    var sourceSender: String = ""
    /// RFC822 Message-ID header for provider-neutral email-source resolution.
    var sourceMessageID: String = ""
    /// Provider thread identifier for grouping related email-source Todos.
    var sourceThreadID: String = ""
    /// 발신자 이메일 주소 — 학습 억제 키 (표시명보다 안정적, 예: "no-reply@coupang.com")
    var sourceSenderEmail: String = ""
    /// Opaque authenticated mailbox namespace for email-source Todos.
    var sourceAccountNamespace: String = ""
    /// 이메일 triage 상태 — TodoTriage.rawValue. 기본 "todo" → 기존 항목/수동 항목은 메인 목록 유지
    var triageStatus: String = TodoTriage.todo.rawValue

    // MARK: - Categorization
    var tags: [String] = []

    // MARK: - Calendar Integration

    /// EKEvent.eventIdentifier — 캘린더 등록 후 저장, 중복 방지에 사용
    var calendarEventID: String?
    /// EKEvent.calendarItemExternalIdentifier — iCloud 동기화 후에도 변하지 않는 안정 식별자.
    /// eventIdentifier는 기기마다 다르지만 externalIdentifier는 동일 → 다른 기기에서 중복 등록 방지.
    var calendarEventExternalID: String = ""
    /// CalendarEventOrigin.rawValue. 빈 값은 이전 버전 데이터이며 source로 안전하게 추론한다.
    var calendarEventOrigin: String = ""
    /// 캘린더 동기화가 마지막으로 Todo에 반영한 EKEvent 제목.
    /// 로컬 제목 편집과 캘린더 상류(EventKit) 변경을 구분하는 3-way merge 기준값.
    /// 빈 문자열 = 기준선 없음(이전 버전 데이터).
    var calendarSyncedTitle: String = ""


    // MARK: - v3 Forward-Compat

    /// MemoryService가 이 할 일에 대해 학습한 패턴 메모
    var memoryNotes: String = ""

    // MARK: - AI Priority Extended (v4)

    /// AI가 추천하는 처리 시각 (nil = 추천 없음)
    var aiRecommendedTime: Date?
    /// AI가 알림 필요하다고 판단한 경우 true (NotificationService가 자동 스케줄)
    var aiNeedsNotification: Bool = false
    /// 페르소나와 부합하는 할 일 여부 (목록에서 시각적 배지 표시)
    var aiPersonaFit: Bool = false
    /// AI가 생성한 세부 설명 (priorityReason 한 줄 요약과 별개)
    var aiDetail: String = ""
    /// 우선순위를 산출한 실제 엔진 (PriorityEngine.rawValue). 빈 문자열 = AI 미실행.
    /// "휴리스틱" → LLM 경로 실패로 규칙 기반 폴백됐음을 의미.
    var aiEngine: String = ""
    /// 사용자가 요청한 제공자(rawValue). 빈 문자열 = AI 미실행.
    var aiRequestedProvider: String = ""
    /// 요청 제공자 실패 후 다른 엔진/휴리스틱으로 폴백한 이유.
    var aiFallbackReason: String = ""
    /// 캘린더 주기(반복) 일정에서 import한 todo이면 true — 목록/상세에 고정 배지 표시
    var isFixedSchedule: Bool = false

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String = "",
        notes: String = "",
        startDate: Date? = nil,
        dueDate: Date? = nil,
        source: TodoSource = .manual,
        sourceRef: String = "",
        tags: [String] = [],
        reminderOffsets: [Double] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.dueDate = dueDate
        self.source = source.rawValue
        self.sourceRef = sourceRef
        self.tags = tags
        self.reminderOffsets = reminderOffsets
    }

    // MARK: - Computed Properties

    var todoSource: TodoSource {
        TodoSource(rawValue: source) ?? .manual
    }

    var calendarOrigin: CalendarEventOrigin {
        CalendarEventOrigin(rawValue: calendarEventOrigin)
            ?? CalendarEventOrigin.inferred(from: self)
    }

    /// 이메일 triage 결과 접근자 — 알 수 없는 값은 .todo로 폴백 (수동 항목 보호)
    var triage: TodoTriage {
        TodoTriage(rawValue: triageStatus) ?? .todo
    }


    var manualPriorityEnum: TodoPriority? {
        guard let m = manualPriority else { return nil }
        return TodoPriority(rawValue: m)
    }

    /// 표시용 실효 우선순위: 수동 지정 우선, 없으면 자동 점수
    /// manualPriority는 IntelligenceService가 절대 덮어쓰지 않음
    var effectivePriority: Double {
        if let m = manualPriority {
            return Double(m) / Double(TodoPriority.critical.rawValue)  // 0.2~1.0
        }
        return computedPriorityScore
    }

    /// dueDate까지 남은 시간 (음수 = 이미 지남)
    var timeUntilDue: TimeInterval? {
        dueDate.map { $0.timeIntervalSinceNow }
    }

    /// 캘린더 발생분 조회·타임라인 배치의 기준 시각. 시작이 없으면 마감을 기준점으로 쓴다.
    var scheduleAnchor: Date? { startDate ?? dueDate }

    /// 시작~마감이 실제 구간을 이룰 때만 반환한다.
    var scheduledRange: (start: Date, end: Date)? {
        guard let startDate, let dueDate, dueDate > startDate else { return nil }
        return (startDate, dueDate)
    }

    var isOverdue: Bool {
        guard !isCompleted, let t = timeUntilDue else { return false }
        return t < 0
    }

    /// dueDate 기준 사람이 읽기 쉬운 상대 시간 문자열
    var dueDateLabel: String? {
        guard let due = dueDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: due, relativeTo: Date())
    }

    /// AI 분석 결과를 반영한다.
    /// 수동 우선순위(manualPriority)가 있으면 덮어쓰지 않는다.
    /// runPrioritize()와 QuickSortService 양쪽에서 공유.
    func apply(_ result: PriorityResult) {
        guard manualPriority == nil else { return }
        computedPriorityScore = result.score
        priorityReason        = result.reason
        aiEngine              = result.engine.rawValue
        aiDetail              = result.detail
        aiNeedsNotification   = result.needsNotification
        aiRecommendedTime     = result.recommendedTime
        aiPersonaFit          = result.personaFit
        aiRequestedProvider   = result.requestedProviderRawValue
        aiFallbackReason      = result.fallbackReason
    }
}

enum TodoPriorityScope {
    static func candidates(from todos: [Todo]) -> [Todo] {
        todos.filter { !$0.isCompleted && $0.triage == .todo && $0.manualPriority == nil }
    }
    @discardableResult
    static func apply(_ result: PriorityResult, in candidates: [Todo]) -> Todo? {
        guard let todo = candidates.first(where: { $0.id == result.todoID }) else { return nil }
        todo.apply(result)
        return todo
    }
}
