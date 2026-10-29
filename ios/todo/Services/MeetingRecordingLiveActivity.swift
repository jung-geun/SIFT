import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import OSLog
import UIKit
#endif

/// ActivityKit is optional presentation; failure must never interrupt capture.
@MainActor
final class MeetingRecordingLiveActivity {
    static let shared = MeetingRecordingLiveActivity()

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private final class Owner {
        var desired: MeetingRecordingActivitySnapshot?
        var endRequested = false
        var activity: Activity<MeetingRecordingAttributes>?
        var attemptedSessionID: String?
        var sent: MeetingRecordingActivitySnapshot?
        var sentAt: TimeInterval = 0
        var observation: Task<Void, Never>?
    }

    private let logger = Logger(subsystem: "pieroot.sift-todo", category: "RecordingLiveActivity")
    private var owners: [UUID: Owner] = [:]
    private var worker: Task<Void, Never>?
    private var wakeup: Task<Void, Never>?
    private var foregroundObservation: Task<Void, Never>?
    private var unreconciled: [Activity<MeetingRecordingAttributes>]

    private init() {
        // A capture cannot survive process death. Remove its system presentation,
        // serially, before requesting anything for this process's new capture.
        unreconciled = Activity<MeetingRecordingAttributes>.activities
        startWorker()
        foregroundObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self else { return }
                self.startWorker()
            }
        }
    }
    #else
    private init() {}
    #endif

    func update(_ snapshot: MeetingRecordingActivitySnapshot?, ownerID: UUID) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard snapshot != nil || owners[ownerID] != nil else { return }
        let owner = owners[ownerID] ?? Owner()
        owners[ownerID] = owner
        if snapshot == nil {
            owner.endRequested = true
            owner.attemptedSessionID = nil
        }
        owner.desired = snapshot
        wakeup?.cancel()
        wakeup = nil
        startWorker()
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private static func bounded(_ snapshot: MeetingRecordingActivitySnapshot) -> MeetingRecordingActivitySnapshot {
        MeetingRecordingActivitySnapshot(
            sessionID: String(snapshot.sessionID.prefix(64)),
            phase: snapshot.phase,
            elapsedMilliseconds: min(max(0, snapshot.elapsedMilliseconds), 315_576_000_000),
            updatedAt: snapshot.updatedAt,
            sources: snapshot.sources.prefix(5).enumerated().map { index, source in
                // Internal ordinal identity avoids leaking capture labels and
                // guarantees bounded JSON even for an unexpected input ID.
                MeetingRecordingSourceState(id: "\(index):\(source.kind.rawValue):\(source.colorIndex)", kind: source.kind,
                                            colorIndex: source.colorIndex, levels: Array(source.levels.suffix(32)))
            }
        )
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
            self.worker = nil
            self.scheduleNextMeterUpdate()
        }
    }

    private func drain() async {
        while let old = unreconciled.popLast() {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        // Exactly one worker performs all requests, updates and ends. Desired
        // state is re-read after every suspension, including rapid stop/restart.
        while true {
            var performedOperation = false
            for (ownerID, owner) in Array(owners) {
                if let activity = owner.activity,
                   owner.endRequested || owner.desired == nil || owner.desired?.sessionID != owner.sent?.sessionID || !ActivityAuthorizationInfo().areActivitiesEnabled {
                    owner.endRequested = false
                    owner.attemptedSessionID = nil
                    owner.observation?.cancel()
                    owner.observation = nil
                    await activity.end(nil, dismissalPolicy: .immediate)
                    owner.activity = nil
                    owner.sent = nil
                    performedOperation = true
                    break
                }
                guard let desired = owner.desired else {
                    owners.removeValue(forKey: ownerID)
                    continue
                }
                owner.endRequested = false
                if let activity = owner.activity {
                    guard activity.activityState == .active || activity.activityState == .stale else {
                        owner.observation?.cancel()
                        owner.observation = nil
                        owner.activity = nil
                        // Keep attemptedSessionID: user dismissal or OS expiry
                        // must not cause a new request on the next meter frame.
                        continue
                    }
                    let immediate = Self.lifecycleChanged(owner.sent, desired)
                    guard immediate || (desired != owner.sent && ProcessInfo.processInfo.systemUptime - owner.sentAt >= 1) else { continue }
                    owner.sent = desired
                    owner.sentAt = ProcessInfo.processInfo.systemUptime
                    await activity.update(Self.content(desired))
                    performedOperation = true
                    break
                }
                guard owner.attemptedSessionID != desired.sessionID else { continue }
                guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                    owner.attemptedSessionID = desired.sessionID
                    continue
                }
                guard UIApplication.shared.applicationState == .active else { continue }
                owner.attemptedSessionID = desired.sessionID
                let attributes = MeetingRecordingAttributes(ownerID: ownerID)
                do {
                    let encoder = JSONEncoder()
                    let content = Self.content(desired)
                    let payloadBytes = try encoder.encode(content.state).count + encoder.encode(attributes).count
                    guard payloadBytes < 4_096 else {
                        logger.error("Recording Live Activity exceeded the payload limit")
                        continue
                    }
                    let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                    owner.activity = activity
                    owner.sent = desired
                    owner.sentAt = ProcessInfo.processInfo.systemUptime
                    owner.observation = Task { [weak owner] in
                        for await state in activity.activityStateUpdates {
                            guard !Task.isCancelled else { return }
                            if state == .dismissed || state == .ended {
                                guard owner?.activity?.id == activity.id else { return }
                                owner?.activity = nil
                                return
                            }
                        }
                    }
                } catch {
                    // One attempt per capture session, not one per audio sample.
                    logger.error("Unable to start recording Live Activity: \(error.localizedDescription, privacy: .public)")
                }
                performedOperation = true
                break
            }
            if !performedOperation { return }
        }
    }

    private static func lifecycleChanged(_ previous: MeetingRecordingActivitySnapshot?, _ next: MeetingRecordingActivitySnapshot) -> Bool {
        guard let previous else { return true }
        guard previous.phase == next.phase, previous.sources.count == next.sources.count else { return true }
        return zip(previous.sources, next.sources).contains {
            $0.id != $1.id || $0.kind != $1.kind || $0.colorIndex != $1.colorIndex
        }
    }

    private static func content(_ snapshot: MeetingRecordingActivitySnapshot) -> ActivityContent<MeetingRecordingActivitySnapshot> {
        ActivityContent(state: bounded(snapshot),
                        staleDate: snapshot.phase == .paused ? nil : snapshot.updatedAt.addingTimeInterval(15),
                        relevanceScore: 100)
    }

    private func scheduleNextMeterUpdate() {
        guard owners.values.contains(where: { $0.activity != nil && $0.desired != $0.sent }) else { return }
        wakeup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            self.wakeup = nil
            self.startWorker()
        }
    }
    #endif
}
