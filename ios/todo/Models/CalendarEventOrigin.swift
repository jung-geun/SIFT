import Foundation

/// 캘린더 이벤트의 소유·생성 경로. 이벤트 URL 마커와 함께 저장해 재설치 후에도
/// 외부 캘린더 import와 SIFT가 만든 일정을 구분한다.
nonisolated enum CalendarEventOrigin: String, Codable, Sendable, Equatable {
    case externalCalendar = "externalCalendar"
    case siftManual = "siftManual"
    case siftEmail = "siftEmail"
    case siftMeeting = "siftMeeting"
    case siftRecommendation = "siftRecommendation"
    /// An explicit export still carries the local-only health privacy boundary.
    case siftHealth = "siftHealth"

    static func inferred(from todo: Todo) -> CalendarEventOrigin {
        // AI가 imported calendar Todo를 분석했더라도, 외부 이벤트의 소유권을
        // SIFT 추천 일정으로 바꾸면 안 된다.
        if todo.todoSource == .calendar {
            return .externalCalendar
        }
        if todo.isHealthRelated {
            return .siftHealth
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
