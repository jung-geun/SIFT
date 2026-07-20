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
        let pendingRequests = await pendingNotificationRequests()

        // 기존 알림 키워드(todoID)를 가진 알림만 갱신 대상으로 제거하여,
        // 앱 전용 알림 슬롯 누락 없이 기존 예약을 교체한다.
        let managedRequestIDs = pendingRequests.compactMap { request -> String? in
            request.content.userInfo["todoID"] != nil ? request.identifier : nil
        }
        if !managedRequestIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: managedRequestIDs)
        }

        // 미완료 + 확정(todo) + future dueDate 있는 항목만 만료 임박순 정렬
        let candidates = todos
            .filter { ReminderTiming.schedulable($0) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

        var scheduled = 0

        outer: for todo in candidates {
            guard let dueDate = todo.dueDate else { continue }
            // 오프셋 오름차순 (먼 것부터 → 가까운 순)
            for offset in todo.reminderOffsets.sorted() {
                guard scheduled < maxPending else { break outer }
                let fireDate = dueDate.addingTimeInterval(offset)
                guard fireDate > Date() else { continue }  // 이미 지난 알림 skip

                let request = makeRequest(
                    todo: todo,
                    offset: offset,
                    fireDate: fireDate,
                    dueDate: dueDate,
                    language: .current
                )
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
        let todoID = todo.id.uuidString
        Task {
            await cancel(todoID: todoID)
        }
    }

    private func cancel(todoID: String) async {
        let pendingRequests = await pendingNotificationRequests()
        let targetIDs = pendingRequests.compactMap { request -> String? in
            guard let requestTodoID = request.content.userInfo["todoID"] as? String,
                  requestTodoID == todoID else {
                return nil
            }
            return request.identifier
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: targetIDs)
    }

    /// 할 일의 알림을 취소하고 새 offsets 기준으로 재등록
    func update(todo: Todo) async {
        await cancel(todoID: todo.id.uuidString)
        guard ReminderTiming.schedulable(todo), let dueDate = todo.dueDate else { return }

        let center = UNUserNotificationCenter.current()
        for offset in todo.reminderOffsets {
            let fireDate = dueDate.addingTimeInterval(offset)
            guard fireDate > Date() else { continue }
            let request = makeRequest(
                todo: todo,
                offset: offset,
                fireDate: fireDate,
                dueDate: dueDate,
                language: .current
            )
            try? await center.add(request)
        }
    }

    // MARK: - Private Helpers

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func notificationID(todoID: UUID, offset: Double) -> String {
        "\(todoID.uuidString)-\(Int(offset))"
    }

    private func makeRequest(
        todo: Todo,
        offset: Double,
        fireDate: Date,
        dueDate: Date,
        language: AppLanguage
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = todo.title.isEmpty
            ? AppLanguage.localized(
                "notification.todoReminder",
                defaultValue: language == .english ? "To-Do Reminder" : "할 일 알림",
                language: language,
                comment: "Notification fallback title"
            )
            : todo.title
        content.body = reminderBody(offset: offset, dueDate: dueDate, language: language)
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

    private func reminderBody(
        offset: Double,
        dueDate: Date,
        language: AppLanguage
    ) -> String {
        ReminderTiming.notificationBody(
            offset: offset,
            dueDate: dueDate,
            language: language
        )
    }
}

enum ReminderTiming {
    static let automaticLeadOffsets: [TimeInterval] = [
        -72 * 3600,
        -24 * 3600,
        -6 * 3600,
        -2 * 3600,
        -1 * 3600,
        -15 * 60
    ]

    static func schedulable(_ todo: Todo, now: Date = Date()) -> Bool {
        guard !todo.isCompleted,
              todo.triage == .todo,
              let dueDate = todo.dueDate else {
            return false
        }
        return dueDate > now
    }

    static func automaticOffset(now: Date = Date(), dueDate: Date) -> TimeInterval? {
        let minimumFireDate = now.addingTimeInterval(60)
        return automaticLeadOffsets.first { offset in
            dueDate.addingTimeInterval(offset) > minimumFireDate
        }
    }

    static func durationText(
        for offset: TimeInterval,
        language: AppLanguage = .current
    ) -> String {
        let totalMinutes = max(1, Int((abs(offset) / 60).rounded()))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []

        func component(_ value: Int, seconds: TimeInterval, key: String) -> String {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = seconds == 86_400
                ? [.day]
                : seconds == 3_600
                    ? [.hour]
                    : [.minute]
            formatter.unitsStyle = .full
            formatter.collapsesLargestUnit = false
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.calendar?.locale = language.locale
            let formatted = formatter.string(from: seconds * Double(value))
            guard let formatted else {
                return String(format: "%lld", locale: language.locale, Int64(value))
            }
            return formatted
        }

        if days > 0 {
            parts.append(component(days, seconds: 86_400, key: "reminder.duration.days"))
        }
        if hours > 0 {
            parts.append(component(hours, seconds: 3_600, key: "reminder.duration.hours"))
        }
        if minutes > 0 {
            parts.append(component(minutes, seconds: 60, key: "reminder.duration.minutes"))
        }

        return parts.joined(separator: " ")
    }

    static func detailLabel(
        for offset: TimeInterval,
        language: AppLanguage = .current
    ) -> String {
        let format = AppLanguage.localized(
            "reminder.detail.beforeDue",
            defaultValue: language == .english ? "%@ before due" : "마감 %@ 전",
            language: language,
            comment: "Reminder picker label"
        )
        return String(
            format: format,
            locale: language.locale,
            durationText(for: offset, language: language)
        )
    }

    static func notificationBody(
        offset: TimeInterval,
        dueDate: Date,
        calendar: Calendar = .current,
        language: AppLanguage = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeStr = formatter.string(from: dueDate)
        let format = AppLanguage.localized(
            "reminder.notification.body",
            defaultValue: language == .english ? "Due in %@ (%@)" : "%@ 후 마감 (%@)",
            language: language,
            comment: "Scheduled reminder body"
        )
        return String(
            format: format,
            locale: language.locale,
            durationText(for: offset, language: language),
            timeStr
        )
    }
}

// MARK: - Preset Offsets

extension NotificationService {
    /// 자주 쓰는 알림 오프셋 프리셋
    static func presetOffsets(
        language: AppLanguage = .current
    ) -> [(label: String, offset: Double)] {
        [
            (ReminderTiming.detailLabel(for: -15 * 60, language: language), -15 * 60),
            (ReminderTiming.detailLabel(for: -1 * 3600, language: language), -1 * 3600),
            (ReminderTiming.detailLabel(for: -6 * 3600, language: language), -6 * 3600),
            (ReminderTiming.detailLabel(for: -24 * 3600, language: language), -24 * 3600),
            (ReminderTiming.detailLabel(for: -72 * 3600, language: language), -72 * 3600)
        ]
    }

    static var presetOffsets: [(label: String, offset: Double)] {
        presetOffsets(language: .current)
    }
}
