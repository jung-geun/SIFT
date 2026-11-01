import Combine
import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum MeetingAudioDownloadFormat: Sendable { case original, wav }

/// Exported temporary files are copied to the user's chosen destination, not loaded into Data.
nonisolated struct MeetingAudioDownload: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { download in
            SentTransferredFile(download.url)
        }
        .exportingCondition { $0.url.pathExtension.lowercased() == "zip" }
        .suggestedFileName { $0.url.lastPathComponent }
        FileRepresentation(exportedContentType: .wav) { download in
            SentTransferredFile(download.url)
        }
        .exportingCondition { $0.url.pathExtension.lowercased() == "wav" }
        .suggestedFileName { $0.url.lastPathComponent }
    }

    @MainActor
    static func prepare(record: MeetingRecord, in context: ModelContext,
                        sourceID: String? = nil, format: MeetingAudioDownloadFormat = .original) async throws -> Self {
        try Task.checkCancellation()
        if record.isAudioTrackGroup, sourceID == nil {
            guard format == .original else { throw MeetingAudioExporter.ExportError.format }
            let id = record.meetingID
            let payloads = try MeetingAudioTrackStore.tracks(for: record, in: context).map { track in
                guard ![.recording, .paused, .stopping].contains(track.status) else {
                    throw MeetingAudioExporter.ExportError.format
                }
                guard let manifest = track.audioManifest else { throw MeetingAudioExporter.ExportError.format }
                return MeetingAudioTrackExport(meetingID: track.meetingID,
                    sourceKind: track.audioTrackKind ?? .legacyMixed, sourceLabel: track.audioTrackSourceLabel,
                    sessionStartSample: track.audioTrackStartSample, manifest: manifest)
            }
            let export = Task.detached(priority: .userInitiated) {
                try MeetingAudioExporter.exportTrackArchive(meetingID: id, tracks: payloads)
            }
            let url = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
            try Task.checkCancellation()
            return Self(url: url)
        }
        let source: MeetingRecord
        if record.isAudioTrackGroup {
            let tracks = try MeetingAudioTrackStore.tracks(for: record, in: context)
            guard let selected = tracks.first(where: { $0.meetingID == sourceID }) else {
                throw MeetingAudioExporter.ExportError.format
            }
            source = selected
        } else {
            guard sourceID == nil || sourceID == record.meetingID else { throw MeetingAudioExporter.ExportError.format }
            source = record
        }
        guard ![.recording, .paused, .stopping].contains(source.status) else {
            throw MeetingAudioExporter.ExportError.format
        }
        guard let manifest = source.audioManifest else { throw MeetingAudioExporter.ExportError.format }
        let export = Task.detached(priority: .userInitiated) {
            switch format {
            case .original: try MeetingAudioExporter.exportSourceArchive(manifest: manifest)
            case .wav: try MeetingAudioExporter.exportMergedAudio(manifest: manifest)
            }
        }
        let url = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
        try Task.checkCancellation()
        return Self(url: url)
    }
}

private struct MeetingAudioDownloadPresenter: ViewModifier {
    @Binding var download: MeetingAudioDownload?
    let onFailure: (Error) -> Void
    #if targetEnvironment(macCatalyst)
    @StateObject private var saver = MeetingAudioNativeSave()
    #endif

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .onChange(of: download?.url) { _, url in
                guard let url else { return }
                saver.save(url) { error in
                    download = nil
                    if let error { onFailure(error) }
                }
            }
            .onDisappear { saver.cancel() }
        #else
        content.fileExporter(
            isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } }),
            item: download,
            contentTypes: [download?.url.pathExtension.lowercased() == "wav" ? .wav : .zip],
            defaultFilename: download?.url.lastPathComponent,
            onCompletion: { result in
                download = nil
                if case .failure(let error) = result { onFailure(error) }
            },
            onCancellation: { download = nil }
        )
        #endif
    }
}

#if targetEnvironment(macCatalyst)
@MainActor
private final class MeetingAudioNativeSave: ObservableObject {
    private lazy var bridge: (any MeetingAudioFilePickerBridging)? = {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RecordingStatusMacSupport.bundle"),
              let bundle = Bundle(url: url) else { return nil }
        do {
            try bundle.loadAndReturnError()
            guard let type = bundle.classNamed("SIFTMeetingAudioFilePickerPlugin") as? any MeetingAudioFilePickerBridging.Type else { return nil }
            return type.init()
        } catch { return nil }
    }()

    func save(_ source: URL, completion: @escaping (Error?) -> Void) {
        guard let bridge else {
            completion(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return
        }
        bridge.saveAudioFile(source) { _, error in completion(error) }
    }

    func cancel() { bridge?.cancelAudioFileSave() }
}
#endif

extension View {
    func meetingAudioDownload(_ download: Binding<MeetingAudioDownload?>,
                              onFailure: @escaping (Error) -> Void) -> some View {
        modifier(MeetingAudioDownloadPresenter(download: download, onFailure: onFailure))
    }
}
