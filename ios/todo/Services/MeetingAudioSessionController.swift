import AVFoundation
import Foundation

final class MeetingAudioSessionController: @unchecked Sendable {
    static let shared = MeetingAudioSessionController()
    private let queue = DispatchQueue(label: "pieroot.todo.meeting.audio-session", qos: .userInitiated)

    /// - Parameter voiceProcessing: when true, configures the session for Apple
    ///   Voice Processing I/O (AEC + noise suppression + AGC) via
    ///   `.playAndRecord`/`.voiceChat`; when false, keeps the raw, minimally
    ///   processed `.record`/`.measurement` path.
    func activateForRecording(voiceProcessing: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if voiceProcessing {
                        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
                    } else {
                        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                    }
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func activateForPlayback() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deactivate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
