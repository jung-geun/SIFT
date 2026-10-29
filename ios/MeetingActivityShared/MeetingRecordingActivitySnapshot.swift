import Foundation

/// Meter history only: no audio, transcript, meeting title or selected-window names.
nonisolated struct MeetingRecordingSourceState: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case microphone, application, screen
    }

    let id: String
    let kind: Kind
    /// Assigned once when a source joins a recording; never reindexed after removal.
    let colorIndex: Int
    /// Oldest to newest, 0...255; at most 32 measured samples per source.
    let levels: [UInt8]
}

nonisolated struct MeetingRecordingActivitySnapshot: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable {
        case recording, paused
    }

    let sessionID: String
    let phase: Phase
    let elapsedMilliseconds: Int64
    let updatedAt: Date
    let sources: [MeetingRecordingSourceState]
}
