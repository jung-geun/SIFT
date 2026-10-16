import Foundation

/// Local evidence about checkoffs, not proof that the named activity actually occurred.
nonisolated struct LearnedRoutine: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var activityKey: String
    var title: String
    var periodDays: Int
    var preferredHour: Int
    var preferredMinute: Int
    var estimatedDurationMinutes: Int
    var sampleCount: Int
    var confidence: Double
    var evidenceStart: Date
    var evidenceEnd: Date
    var nextOccurrence: Date
    var isConfirmed: Bool = false
    var uncertainty: String
    var updatedAt: Date
    var distinctCompletionDays: Int = 0
    var recordedCompletionHours: [Int] = []
    var timeZoneIdentifier: String = TimeZone.current.identifier
    /// Confirming a candidate is an explicit approval of its editable scheduling fields.
    var hasManualOverrides: Bool = false
    var isSuppressed: Bool = false
    /// An explicit schedule edit can replace a low-confidence inferred schedule.
    var isScheduleManuallySpecified: Bool = false

    var dayPeriod: RoutineDayPeriod { RoutineDayPeriod(hour: preferredHour) }
}

nonisolated enum RoutineDayPeriod: String, Codable, Sendable {
    case night, morning, afternoon, evening

    init(hour: Int) {
        switch hour {
        case 6..<12: self = .morning
        case 12..<18: self = .afternoon
        case 18..<22: self = .evening
        default: self = .night
        }
    }
}

nonisolated struct RoutineFeedback: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum Action: String, Codable, Sendable { case accepted, rejected, postponed }

    var id: UUID = UUID()
    var routineID: UUID
    /// Stable local-calendar occurrence anchor; postponing never replaces this anchor.
    var occurrence: Date
    var action: Action
    var suggestedTime: Date
    var appliedTime: Date? = nil
    var todoID: UUID? = nil
    var recordedAt: Date = Date()
}

nonisolated struct RoutineSuggestion: Identifiable, Equatable, Sendable {
    var routineID: UUID
    var title: String
    var occurrence: Date
    var preferredStart: Date
    var estimatedDurationMinutes: Int

    var id: String { sourceRef }
    var sourceRef: String { Self.sourceRef(routineID: routineID, occurrence: occurrence) }

    static func sourceRef(routineID: UUID, occurrence: Date) -> String {
        "routine:\(routineID.uuidString.lowercased()):\(Int64(occurrence.timeIntervalSince1970.rounded()))"
    }
}

/// A durable reservation bridging the local JSON store and the parent's SwiftData save.
nonisolated struct RoutineAcceptance: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var routineID: UUID
    var occurrence: Date
    var suggestedTime: Date
    var appliedTime: Date
    var todoID: UUID
    var recordedAt: Date

    var sourceRef: String { RoutineSuggestion.sourceRef(routineID: routineID, occurrence: occurrence) }
}

nonisolated enum RoutineStoreError: LocalizedError {
    case learningDisabled, invalidRoutine, invalidFeedback, duplicateOccurrence, staleSuggestion
    case acceptanceNotFound, storeUnavailable, unreliableSchedule, saveFailed

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .learningDisabled:
            return AppLanguage.localized(
                "error.routine.learningDisabled",
                defaultValue: language == .english ? "Routine learning is turned off." : "루틴 학습이 꺼져 있습니다.",
                language: language,
                comment: "Routine store error when learning is disabled."
            )
        case .invalidRoutine:
            return AppLanguage.localized(
                "error.routine.invalidRoutine",
                defaultValue: language == .english ? "The routine needs a title, valid local time, period and duration." : "루틴에 제목과 올바른 현지 시간, 반복 주기, 소요 시간이 필요합니다.",
                language: language,
                comment: "Routine store error for invalid editable scheduling fields."
            )
        case .unreliableSchedule:
            return AppLanguage.localized(
                "error.routine.unreliableSchedule",
                defaultValue: language == .english ? "The completion intervals are irregular. Edit the recurrence or preferred time before confirming." : "완료 간격이 불규칙합니다. 확정하기 전에 반복 주기나 선호 시간을 수정해 주세요.",
                language: language,
                comment: "Routine confirmation error requiring a manual schedule for irregular evidence."
            )
        case .invalidFeedback:
            return AppLanguage.localized(
                "error.routine.invalidFeedback",
                defaultValue: language == .english ? "The routine feedback is incomplete or conflicts with an accepted occurrence." : "루틴 피드백이 불완전하거나 이미 수락한 회차와 충돌합니다.",
                language: language,
                comment: "Routine store error for incomplete or conflicting occurrence feedback."
            )
        case .duplicateOccurrence:
            return AppLanguage.localized(
                "error.routine.duplicateOccurrence",
                defaultValue: language == .english ? "This routine occurrence already has a task or decision." : "이 루틴 회차에는 이미 할 일이나 결정이 있습니다.",
                language: language,
                comment: "Routine store error preventing a duplicate task or decision for an occurrence."
            )
        case .staleSuggestion:
            return AppLanguage.localized(
                "error.routine.staleSuggestion",
                defaultValue: language == .english ? "The routine suggestion changed. Refresh it before accepting." : "루틴 제안이 변경되었습니다. 수락하기 전에 새로고침해 주세요.",
                language: language,
                comment: "Routine store error when a suggestion changed before acceptance."
            )
        case .acceptanceNotFound:
            return AppLanguage.localized(
                "error.routine.acceptanceNotFound",
                defaultValue: language == .english ? "The pending routine acceptance was not found." : "대기 중인 루틴 수락 기록을 찾을 수 없습니다.",
                language: language,
                comment: "Routine store error when a pending acceptance reservation is missing."
            )
        case .storeUnavailable:
            return AppLanguage.localized(
                "error.routine.storeUnavailable",
                defaultValue: language == .english ? "The local routine store could not be read. No changes were saved." : "로컬 루틴 저장소를 읽을 수 없습니다. 변경 사항은 저장되지 않았습니다.",
                language: language,
                comment: "Generic routine store read error; never include paths or underlying diagnostics."
            )
        case .saveFailed:
            return AppLanguage.localized(
                "error.routine.saveFailed",
                defaultValue: language == .english ? "The local routine change could not be saved. Please try again." : "로컬 루틴 변경 사항을 저장할 수 없습니다. 다시 시도해 주세요.",
                language: language,
                comment: "Generic routine store write error; never include paths or underlying diagnostics."
            )
        }
    }
}
