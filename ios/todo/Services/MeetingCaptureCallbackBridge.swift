import Foundation

final class MeetingCaptureCallbackBridge: @unchecked Sendable {
    weak var coordinator: MeetingCaptureCoordinator?

    init(_ coordinator: MeetingCaptureCoordinator) {
        self.coordinator = coordinator
    }
}
