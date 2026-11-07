import Combine
import Foundation
import SwiftUI

enum CloudSyncPhase: Equatable {
    case idle
    case importing
    case completed
}

/// UI projection of the full service's confirmed import AND local restore.
/// Item counts are progress hints, never evidence that CloudKit finished.
@MainActor
final class CloudSyncMonitor: ObservableObject {
    @Published private(set) var phase: CloudSyncPhase = .idle
    @Published private(set) var importedCount = 0
    private var baselineCount = 0
    private var subscription: AnyCancellable?
    private var completionTask: Task<Void, Never>?
    private var hasCompletedInitialBanner = false
    private let statusPublisher: AnyPublisher<(Bool, String?), Never>
    private let completionDuration: Duration

    init(
        statusPublisher: AnyPublisher<(Bool, String?), Never>? = nil,
        completionDuration: Duration = .seconds(2)
    ) {
        self.completionDuration = completionDuration
        if let statusPublisher {
            self.statusPublisher = statusPublisher
        } else {
            let service = FullCloudSyncService.shared
            self.statusPublisher = service.$hasFinishedInitialRestore
                .combineLatest(service.$errorMessage)
                .eraseToAnyPublisher()
        }
    }

    func startObserving(initialCount: Int) {
        guard UserCloudSyncPolicy.isRequested else { stopObserving(); return }
        guard subscription == nil else {
            updateBaseline(initialCount)
            return
        }
        baselineCount = initialCount
        importedCount = 0
        if !hasCompletedInitialBanner, phase != .importing {
            phase = .importing
        }
        subscription = statusPublisher
            .removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 })
            .receive(on: RunLoop.main)
            .sink { [weak self] finished, error in
                guard let self else { return }
                guard UserCloudSyncPolicy.isRequested, error == nil else {
                    if self.phase != .idle { self.phase = .idle }
                    return
                }
                if finished {
                    self.finishImport()
                } else if !self.hasCompletedInitialBanner, self.phase != .importing {
                    self.phase = .importing
                }
            }
    }

    func stopObserving() {
        subscription = nil
        completionTask?.cancel()
        completionTask = nil
        hasCompletedInitialBanner = false
        if phase != .idle { phase = .idle }
        if importedCount != 0 { importedCount = 0 }
    }

    func updateCount(_ total: Int) {
        guard phase == .importing else { return }
        importedCount = max(0, total - baselineCount)
    }

    func updateBaseline(_ count: Int) {
        guard phase == .importing, baselineCount == 0, count > 0 else { return }
        baselineCount = count
        importedCount = 0
    }

    func waitForCompletion(timeout: TimeInterval = 12) async -> Bool {
        await FullCloudSyncService.shared.waitForInitialRestore(timeout: timeout)
    }

    private func finishImport() {
        guard !hasCompletedInitialBanner, phase == .importing else { return }
        hasCompletedInitialBanner = true
        completionTask?.cancel()
        withAnimation { phase = .completed }
        let duration = completionDuration
        completionTask = Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard !Task.isCancelled else { return }
            if phase != .idle {
                withAnimation { phase = .idle }
            }
        }
    }
}
