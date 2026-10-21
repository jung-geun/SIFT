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

    func startObserving(initialCount: Int) {
        guard UserCloudSyncPolicy.isRequested else { stopObserving(); return }
        guard subscription == nil else {
            updateBaseline(initialCount)
            return
        }
        baselineCount = initialCount
        importedCount = 0
        phase = .importing
        let service = FullCloudSyncService.shared
        subscription = service.$hasFinishedInitialRestore.combineLatest(service.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] finished, error in
                guard let self else { return }
                guard UserCloudSyncPolicy.isRequested, error == nil else {
                    self.phase = .idle
                    return
                }
                if finished { self.finishImport() }
                else { self.phase = .importing }
            }
    }

    func stopObserving() {
        subscription = nil
        completionTask?.cancel()
        completionTask = nil
        phase = .idle
        importedCount = 0
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
        guard phase != .completed else { return }
        completionTask?.cancel()
        withAnimation { phase = .completed }
        completionTask = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation { phase = .idle }
        }
    }
}
