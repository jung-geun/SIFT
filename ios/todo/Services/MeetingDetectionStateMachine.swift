import Foundation

/// Deliberately outside the cloud-portable `pieroot.todo.` preference namespace.
/// Never migrate remote or old namespace values into device-local monitoring consent.
nonisolated enum MeetingDetectionPreferenceKey {
    static let enabled = "SIFT.local.meetingDetection.enabled"
    static func allowedApplication(_ bundleID: String) -> String {
        "SIFT.local.meetingDetection.allow." + bundleID
    }
}

/// No process names, audio, or detection history are persisted.
nonisolated struct MeetingDetectionCandidate: Equatable, Sendable {
    let sessionID: String
    let processID: Int32
    let bundleIdentifier: String
    let displayName: String
    let isBrowser: Bool
    let runningInput: Bool
    let runningOutput: Bool

    var isCallLike: Bool { runningInput && runningOutput }
}

nonisolated struct MeetingDetectionSuggestion: Equatable, Sendable {
    let token: UUID
    let candidate: MeetingDetectionCandidate
    let expiresAt: Date
}

/// Pure wall-clock state machine. Brief mute/output gaps never create a second suggestion.
nonisolated struct MeetingDetectionStateMachine {
    var stabilization: TimeInterval = 3
    var sessionEndDelay: TimeInterval = 60
    var promptDuration: TimeInterval = 30
    private(set) var suggestion: MeetingDetectionSuggestion?
    private var sessions: [String: Session] = [:]

    private struct Session {
        var candidate: MeetingDetectionCandidate
        var activeSince: Date?
        var inactiveSince: Date?
        var handled = false
    }

    mutating func observe(_ candidates: [MeetingDetectionCandidate], at now: Date,
                          recordingActive: Bool) -> MeetingDetectionSuggestion? {
        let current = Dictionary(candidates.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        // A terminated process ends a session immediately; audio inactivity needs a quiet interval.
        sessions = sessions.filter { current[$0.key] != nil }
        for candidate in candidates {
            var session = sessions[candidate.sessionID] ?? Session(candidate: candidate)
            session.candidate = candidate
            if candidate.isCallLike {
                if let inactive = session.inactiveSince, now.timeIntervalSince(inactive) >= sessionEndDelay {
                    session.handled = false
                }
                session.inactiveSince = nil
                if session.activeSince == nil { session.activeSince = now }
            } else {
                session.activeSince = nil
                if !candidate.runningInput && !candidate.runningOutput {
                    if session.inactiveSince == nil { session.inactiveSince = now }
                } else {
                    // Muting just the mic (or output) is still the same call session.
                    session.inactiveSince = nil
                }
                if let inactive = session.inactiveSince, now.timeIntervalSince(inactive) >= sessionEndDelay {
                    session.handled = false
                }
            }
            if recordingActive && candidate.isCallLike { session.handled = true }
            sessions[candidate.sessionID] = session
        }
        if let prompt = suggestion {
            if recordingActive || now >= prompt.expiresAt || current[prompt.candidate.sessionID]?.isCallLike != true {
                // Expiry, skip, or a mute during the panel consumes this session's suggestion.
                sessions[prompt.candidate.sessionID]?.handled = true
                suggestion = nil
            }
        }
        guard !recordingActive, suggestion == nil else { return suggestion }
        let eligible = sessions.values.filter {
            !$0.handled && $0.candidate.isCallLike && $0.activeSince.map { now.timeIntervalSince($0) >= stabilization } == true
        }.sorted { $0.candidate.sessionID < $1.candidate.sessionID }
        if let session = eligible.first {
            sessions[session.candidate.sessionID]?.handled = true
            suggestion = MeetingDetectionSuggestion(token: UUID(), candidate: session.candidate,
                                                    expiresAt: now.addingTimeInterval(promptDuration))
        }
        return suggestion
    }

    mutating func dismiss(token: UUID) {
        guard suggestion?.token == token else { return }
        suggestion = nil
    }

    mutating func accept(token: UUID, at now: Date, recordingActive: Bool) -> MeetingDetectionCandidate? {
        guard !recordingActive, let prompt = suggestion, prompt.token == token,
              now < prompt.expiresAt, sessions[prompt.candidate.sessionID]?.candidate.isCallLike == true else {
            if suggestion?.token == token { suggestion = nil }
            return nil
        }
        suggestion = nil
        return prompt.candidate
    }

    mutating func reset() {
        sessions.removeAll()
        suggestion = nil
    }
}

nonisolated struct MeetingDetectedStartIntent: Identifiable, Equatable, Sendable {
    let id: UUID
    let processID: Int32
    let bundleIdentifier: String
    let displayName: String
    let expiresAt: Date
}
