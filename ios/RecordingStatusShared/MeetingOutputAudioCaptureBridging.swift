import Foundation

/// Borrowed AudioBufferList and AudioStreamBasicDescription pointers, valid until return.
/// This Foundation-only ABI is compiled into both the Catalyst app and native bundle.
@objc(SIFTMeetingOutputAudioCaptureBridging)
nonisolated protocol MeetingOutputAudioCaptureBridging: NSObjectProtocol {
    init()
    func outputDevices() throws -> [[String: Any]]
    func start(deviceUID: String?, streamIndex: UInt32, processID: Int32,
               receive: @escaping @Sendable (UnsafeRawPointer, UnsafeRawPointer, Double) -> Void,
               failed: @escaping @Sendable (NSError) -> Void,
               completion: @escaping @Sendable (NSError?) -> Void)
    func stop()
}
