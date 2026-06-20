import Foundation
import UserNotifications

/// 할 일의 다단계 알림을 관리.
///
/// iOS pending 알림 한계(64개)를 슬라이딩 윈도우로 대응:
/// 만료 임박순 상위 항목만 등록하고 포그라운드 진입 시 재스케줄.
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    /// 안전 마진을 둔 최대 pending 알림 수 (iOS 상한 64 - 여유 4)
    private let maxPending = 60

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Reschedule (슬라이딩 윈도우)

    /// 모든 할 일을 기준으로 알림을 재스케줄.
    /// 앱 포그라운드 진입, 데이터 변경, v2 백그라운드 깨어남 시 호출.
    func reschedule(todos: [Todo]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        // 미완료 + dueDate 있는 항목을 마감 임박순 정렬
        let candidates = todos
            .filter { !$0.isCompleted && $0.dueDate != nil && ($0.dueDate! > Date()) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

        var scheduled = 0

        outer: for todo in candidates {
            guard let dueDate = todo.dueDate else { continue }
            // 오프셋 오름차순 (먼 것부터 → 가까운 순)
            for offset in todo.reminderOffsets.sorted() {
                guard scheduled < maxPending else { break outer }
                let fireDate = dueDate.addingTimeInterval(offset)
                guard fireDate > Date() else { continue }  // 이미 지난 알림 skip

                let request = makeRequest(todo: todo, offset: offset, fireDate: fireDate, dueDate: dueDate)
                do {
                    try await center.add(request)
                    scheduled += 1
                } catch {
                    // 개별 알림 실패는 무시하고 계속
                }
            }
        }
    }

    // MARK: - Cancel

    /// 특정 할 일에 등록된 알림 전체 취소
    func cancel(todo: Todo) {
        let ids = todo.reminderOffsets.map { notificationID(todoID: todo.id, offset: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 할 일의 알림을 취소하고 새 offsets 기준으로 재등록
    func update(todo: Todo) async {
        cancel(todo: todo)
        guard !todo.isCompleted, let dueDate = todo.dueDate, dueDate > Date() else { return }

        let center = UNUserNotificationCenter.current()
        for offset in todo.reminderOffsets {
            let fireDate = dueDate.addingTimeInterval(offset)
            guard fireDate > Date() else { continue }
            let request = makeRequest(todo: todo, offset: offset, fireDate: fireDate, dueDate: dueDate)
            try? await center.add(request)
        }
    }

    // MARK: - Private Helpers

    private func notificationID(todoID: UUID, offset: Double) -> String {
        "\(todoID.uuidString)-\(Int(offset))"
    }

    private func makeRequest(
        todo: Todo,
        offset: Double,
        fireDate: Date,
        dueDate: Date
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = todo.title.isEmpty ? "할 일 알림" : todo.title
        content.body = reminderBody(offset: offset, dueDate: dueDate)
        content.sound = .default
        content.userInfo = ["todoID": todo.id.uuidString]

        // 우선순위 뱃지
        if todo.effectivePriority >= 0.8 {
            content.interruptionLevel = .timeSensitive
        }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(
            identifier: notificationID(todoID: todo.id, offset: offset),
            content: content,
            trigger: trigger
        )
    }

    private func reminderBody(offset: Double, dueDate: Date) -> String {
        let absOffset = abs(offset)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeStr = formatter.string(from: dueDate)

        switch absOffset {
        case ..<3660:    return "1시간 후 마감 (\(timeStr))"
        case ..<21660:   return "6시간 후 마감 (\(timeStr))"
        case ..<86460:   return "내일 마감 (\(timeStr))"
        default:
            let hours = Int(absOffset / 3600)
            return "\(hours)시간 후 마감 (\(timeStr))"
        }
    }
}

// MARK: - Preset Offsets

extension NotificationService {
    /// 자주 쓰는 알림 오프셋 프리셋
    static let presetOffsets: [(label: String, offset: Double)] = [
        ("마감 15분 전",    -15 * 60),
        ("마감 1시간 전",   -1  * 3600),
        ("마감 6시간 전",   -6  * 3600),
        ("마감 하루 전",    -24 * 3600),
        ("마감 3일 전",     -72 * 3600),
    ]
}
