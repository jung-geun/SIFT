import Foundation

/// A capture target is not a meeting participant. Screen audio may already mix
/// several remote speakers; only this track's own samples supply voice evidence.
nonisolated enum MeetingAudioTrackKind: String, Codable, Sendable {
    case microphone, screen, application, legacyMixed

    func displayName(language: AppLanguage = .current) -> String {
        let key: String
        let english: String
        let korean: String
        switch self {
        case .microphone: (key, english, korean) = ("meeting.audioTrack.kind.microphone", "Microphone", "마이크")
        case .screen: (key, english, korean) = ("meeting.audioTrack.kind.screen", "Screen audio", "화면 오디오")
        case .application: (key, english, korean) = ("meeting.audioTrack.kind.application", "Application audio", "앱 오디오")
        case .legacyMixed: (key, english, korean) = ("meeting.audioTrack.kind.legacy", "Existing recording", "기존 녹음")
        }
        return AppLanguage.localized(key, defaultValue: language == .english ? english : korean,
                                     language: language, comment: "Independent recording source kind.")
    }
}

/// Each child ID owns a FLAC directory, transcript namespace, and diarizer state.
/// `sessionStartSample` locates local sample zero on the parent capture timeline.
/// Source labels are local user content and must never enter diagnostics.
nonisolated struct MeetingCaptureTrackArtifact: Sendable {
    let meetingID: String
    let sourceKind: MeetingAudioTrackKind
    let sourceLabel: String?
    let sessionStartSample: Int64
    let directoryURL: URL
    let audioManifest: MeetingAudioManifest
    let provisionalResult: MeetingResult
}
