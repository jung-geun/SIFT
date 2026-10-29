import Combine
import Foundation

extension Notification.Name {
    static let meetingRecordingOpen = Notification.Name("SIFTMeetingRecordingOpen")
}

/// Glanceable capture state shared across tabs and windows, never a second audio owner.
@MainActor
final class MeetingRecordingActivityCenter: ObservableObject {
    static let shared = MeetingRecordingActivityCenter()

    @Published private(set) var current: MeetingRecordingActivitySnapshot?
    @Published private(set) var navigationRequestID: UUID?
    private var snapshots: [UUID: MeetingRecordingActivitySnapshot] = [:]
    private var ownerOrder: [UUID] = []

    func requestOpenRecording() {
        navigationRequestID = UUID()
        NotificationCenter.default.post(name: .meetingRecordingOpen, object: nil)
    }

    func clearNavigationIntent() {
        navigationRequestID = nil
    }

    func update(_ snapshot: MeetingRecordingActivitySnapshot?, ownerID: UUID) {
        #if targetEnvironment(macCatalyst)
        if let previous = snapshots[ownerID], previous.sessionID != snapshot?.sessionID {
            MeetingRecordingMacSceneRegistry.shared.clear(sessionID: previous.sessionID)
        }
        #endif
        if let snapshot {
            if snapshots[ownerID] == nil { ownerOrder.append(ownerID) }
            snapshots[ownerID] = snapshot
        } else {
            snapshots[ownerID] = nil
            ownerOrder.removeAll { $0 == ownerID }
        }
        current = ownerOrder.last.flatMap { snapshots[$0] }
        if current == nil { clearNavigationIntent() }
        #if targetEnvironment(macCatalyst)
        if current == nil { MeetingRecordingMacSceneRegistry.shared.clearAll() }
        MeetingRecordingMacStatusItem.shared.update(current)
        #endif
        MeetingRecordingLiveActivity.shared.update(snapshot, ownerID: ownerID)
    }
}
