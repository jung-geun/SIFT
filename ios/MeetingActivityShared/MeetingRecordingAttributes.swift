#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

nonisolated struct MeetingRecordingAttributes: ActivityAttributes {
    typealias ContentState = MeetingRecordingActivitySnapshot

    /// Capture owner identity only, never a meeting title or selected-window name.
    let ownerID: UUID
}
#endif
