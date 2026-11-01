#if targetEnvironment(macCatalyst)
import Foundation
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    func copiedFileURLs() -> [URL] { bridge?.copiedFileURLs() ?? [] }
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

/// A keyboard-only form background or a visible, interactive file drop zone.
/// Text fields keep ordinary paste; scrolling cannot retire the form command.
struct MeetingAudioFileInput: UIViewRepresentable {
    let enabled: Bool
    var paste: (() -> Void)? = nil
    var drop: (([NSItemProvider]) -> Bool)? = nil
    var targeted: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> PasteView {
        let view = PasteView()
        if drop != nil { view.addInteraction(UIDropInteraction(delegate: view)) }
        return view
    }

    func updateUIView(_ view: PasteView, context: Context) {
        view.enabled = enabled
        view.onPaste = paste
        view.onDrop = drop
        view.onTargeted = targeted
    }

    static func dismantleUIView(_ view: PasteView, coordinator: ()) {
        view.resignFirstResponder()
        view.onPaste = nil
        view.onDrop = nil
        view.onTargeted = nil
    }

    final class PasteView: UIView, UIDropInteractionDelegate {
        var enabled = true
        var onPaste: (() -> Void)?
        var onDrop: (([NSItemProvider]) -> Bool)?
        var onTargeted: ((Bool) -> Void)?
        override var canBecomeFirstResponder: Bool { onPaste != nil }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            onDrop != nil && super.point(inside: point, with: event)
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            enabled && session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier, UTType.audio.identifier])
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
            onTargeted?(true)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: enabled ? .copy : .forbidden)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
            onTargeted?(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
            onTargeted?(false)
            if enabled { _ = onDrop?(session.items.map(\.itemProvider)) }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
            onTargeted?(false)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, onPaste != nil { becomeFirstResponder() }
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            action == #selector(paste(_:)) ? enabled && onPaste != nil : super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            if enabled { onPaste?() }
        }
    }
}
#endif
