import Foundation

nonisolated enum HealthHistoryCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case workout, medication
    var id: String { rawValue }
}

/// A projection of a real HealthKit sample, not a manual task completion.
/// Medication amount, unit, prescribed schedule and adherence are deliberately not retained.
nonisolated struct HealthHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var category: HealthHistoryCategory
    var kindKey: String
    var title: String
    var startDate: Date
    var sourceID: String
    var sourceName: String
    var wasTaken: Bool = true
}

@MainActor
protocol HealthHistoryReading {
    func unavailableReason(for category: HealthHistoryCategory) -> String?
    /// Completing the prompt is NOT proof of read authorization.
    func requestRead(for category: HealthHistoryCategory) async throws
    func history(for category: HealthHistoryCategory, from: Date, through: Date) async throws -> [HealthHistoryRecord]
}

nonisolated struct HealthRoutineCandidate: Codable, Equatable, Identifiable, Sendable {
    /// Stable within a category, activity/medication identity and source application.
    var id: String
    var category: HealthHistoryCategory
    var kindKey: String
    var title: String
    var sourceID: String
    var sourceName: String
    var recordCount: Int
    var distinctDays: Int
    var evidenceStart: Date
    var evidenceEnd: Date
    var regularity: Double
    var periodDays: Int
    var hour: Int
    var minute: Int
    var anchorDate: Date
    var timeZoneIdentifier: String
    var isConfirmed = false
    var isEnabled = false
}

nonisolated struct HealthCategoryState: Codable, Equatable, Sendable {
    var isConnected = false
    /// An empty set approves no source. A newly observed source always requires approval.
    var approvedSourceIDs: Set<String> = []
    var lastRead: Date?
    var readRecordCount = 0
}

nonisolated enum HealthHistoryError: LocalizedError {
    case unavailable(String), storage, invalidSchedule
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .storage: return HealthCopy.text("health.error.storage", "Protected health history could not be saved or read. Automatic creation is stopped. Reset local health data to recover.", "보호된 건강 기록을 저장하거나 읽을 수 없어 자동 생성을 중지했습니다. 로컬 건강 데이터를 초기화하여 복구하세요.")
        case .invalidSchedule: return HealthCopy.text("health.error.schedule", "Review a supported schedule and a nonempty task title before confirming.", "지원되는 주기와 비어 있지 않은 할 일 제목을 확인하세요.")
        }
    }
}
