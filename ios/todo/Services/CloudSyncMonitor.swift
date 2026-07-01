import Foundation
import CoreData
import Combine
import SwiftUI

// MARK: - iCloud 동기화 페이즈

enum CloudSyncPhase: Equatable {
    case idle
    case importing
    case completed
}

// MARK: - CloudSyncMonitor

/// NSPersistentCloudKitContainer.eventChangedNotification을 구독해
/// 실제 CloudKit import 시작/완료를 감지하는 관찰자.
///
/// 폴백: 이벤트가 3초 내에 도착하지 않으면 타이머 기반 휴리스틱으로 degrade.
@MainActor
final class CloudSyncMonitor: ObservableObject {

    // MARK: - Published

    @Published private(set) var phase: CloudSyncPhase = .idle
    @Published private(set) var importedCount: Int = 0

    // MARK: - Private

    private var baselineCount: Int = 0
    private var cancellables: Set<AnyCancellable> = []
    private var fallbackTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var gotRealEvent = false

    // MARK: - Start / Stop

    /// iCloud 동기화 시작 시 호출. initialCount = 현재 @Query 총 항목 수.
    func startObserving(initialCount: Int) {
        stopObserving()
        baselineCount = initialCount
        importedCount = 0
        gotRealEvent = false

        // 실제 CloudKit import 이벤트 구독
        NotificationCenter.default.publisher(
            for: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleEvent(notification)
        }
        .store(in: &cancellables)

        withAnimation { phase = .importing }

        // 폴백: 3초 내 실제 이벤트 미도착 시 8초 타이머로 완료 처리
        fallbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !gotRealEvent else { return }
            // 실제 이벤트 없음 — 타이머 기반 완료 처리 (변경사항이 없으면 이벤트가 오지 않을 수 있음)
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, phase == .importing else { return }
            print("[CloudSyncMonitor] CloudKit 이벤트 미도착 (변경사항 없음 혹은 오프라인), 상태 완료로 전환")
            finishImport()
        }
    }

    /// 관찰 중지 및 상태 초기화.
    func stopObserving() {
        cancellables.removeAll()
        fallbackTask?.cancel()
        completionTask?.cancel()
        fallbackTask = nil
        completionTask = nil
        phase = .idle
        importedCount = 0
        gotRealEvent = false
    }

    /// @Query 항목 합계가 바뀔 때 호출 — importing 중 라이브 카운트 갱신.
    func updateCount(_ total: Int) {
        guard phase == .importing else { return }
        let arrived = max(0, total - baselineCount)
        importedCount = arrived
    }

    /// 앱 레벨에서 initialCount: 0으로 시작한 경우, TodoListView가 실제 @Query 총수를
    /// 알게 된 시점에 기준치를 보정한다. importing 중 최초 1회만 동작.
    func updateBaseline(_ count: Int) {
        guard phase == .importing, baselineCount == 0, count > 0 else { return }
        baselineCount = count
        importedCount = 0
    }

    // MARK: - CloudKit Event 처리

    private func handleEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[
            NSPersistentCloudKitContainer.eventNotificationUserInfoKey
        ] as? NSPersistentCloudKitContainer.Event else { return }

        // import 이벤트만 처리 (setup / export 무시)
        guard event.type == .import else { return }

        gotRealEvent = true
        fallbackTask?.cancel() // 폴백 불필요

        if event.endDate == nil {
            // Import 진행 중
            withAnimation { phase = .importing }
        } else {
            // Import 완료
            print("[CloudSyncMonitor] CloudKit import 완료 (succeeded: \(event.succeeded))")
            finishImport()
        }
    }

    // MARK: - 완료 대기

    /// iCloud import가 완료될 때까지 대기 (최대 timeout 초).
    /// phase가 .importing이 아니면 즉시 반환.
    /// 타임아웃 시에도 반환 — 캘린더 동기화가 다소 늦게 실행되는 것보다 안전함.
    func waitForCompletion(timeout: TimeInterval = 12) async {
        guard phase == .importing else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while phase == .importing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: - 완료 처리

    private func finishImport() {
        completionTask?.cancel()
        completionTask = Task {
            withAnimation { phase = .completed }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { phase = .idle }
        }
    }
}
