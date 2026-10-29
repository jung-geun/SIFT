#if targetEnvironment(macCatalyst)
import Foundation
import Combine

/// Catalyst's document picker may try to present from a detached SwiftUI host.
/// Use the existing same-process AppKit support bundle and its actual key window.
@MainActor
final class MeetingAudioFilePicker: ObservableObject {
    @Published private(set) var isPresented = false
    private lazy var bridge: (any MeetingAudioFilePickerBridging)? = Self.loadBridge()

    func choose(_ completion: @escaping (Result<URL?, MeetingAudioImportService.Failure>) -> Void) {
        guard !isPresented else { return }
        guard let bridge else {
            completion(.failure(.unavailableInput))
            return
        }
        isPresented = true
        bridge.chooseAudioFile { [weak self] url, error in
            self?.isPresented = false
            if error != nil { completion(.failure(.unavailableInput)) }
            else { completion(.success(url)) }
        }
    }

    func cancel() {
        guard isPresented else { return }
        bridge?.cancelAudioFilePicker()
    }

    private static func loadBridge() -> (any MeetingAudioFilePickerBridging)? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RecordingStatusMacSupport.bundle"),
              let bundle = Bundle(url: url) else { return nil }
        do {
            try bundle.loadAndReturnError()
            guard let type = bundle.classNamed("SIFTMeetingAudioFilePickerPlugin") as? any MeetingAudioFilePickerBridging.Type else { return nil }
            return type.init()
        } catch { return nil }
    }
}
#endif
