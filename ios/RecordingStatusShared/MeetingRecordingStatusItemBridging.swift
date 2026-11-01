import Foundation

/// Foundation-only ABI shared by the Catalyst executable and its native macOS bundle.
/// The explicit Objective-C name preserves protocol identity across the two modules.
@MainActor
@objc(SIFTMeetingRecordingStatusItemBridging)
protocol MeetingRecordingStatusItemBridging: NSObjectProtocol {
    init()
    func setOpenRecordingAction(_ action: @escaping () -> Void)
    func present(paused: Bool, elapsedSeconds: Int64, phaseLabel: String, openRecordingLabel: String)
    func clear()
    func invalidate()
}

/// File selection stays native on Mac; no UIKit detached presentation host.
@MainActor
@objc(SIFTMeetingAudioFilePickerBridging)
protocol MeetingAudioFilePickerBridging: NSObjectProtocol {
    init()
    func chooseAudioFile(_ completion: @escaping (URL?, NSError?) -> Void)
    func cancelAudioFilePicker()
    func copiedFileURLs() -> [URL]
    func saveAudioFile(_ source: URL, completion: @escaping (URL?, NSError?) -> Void)
    func cancelAudioFileSave()
}

/// Detection reads process metadata only. This ABI exposes no audio buffers or capture operations.
@MainActor
@objc(SIFTMeetingDetectionBridging)
protocol MeetingDetectionBridging: NSObjectProtocol {
    init()
    var isSupported: Bool { get }
    func setHandlers(snapshot: @escaping (NSArray) -> Void,
                     lifecycle: @escaping (String) -> Void,
                     decision: @escaping (String, String) -> Void)
    func startMonitoring() -> Bool
    func stopMonitoring()
    func refreshMetadata()
    func presentSuggestion(token: String, title: String, message: String,
                           startLabel: String, skipLabel: String, expiresAt: Date)
    func dismissSuggestion()
    func invalidate()
}
