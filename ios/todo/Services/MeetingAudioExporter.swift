import AVFoundation
import Foundation
import os

nonisolated struct MeetingAudioTrackExport: Codable, Sendable {
    let meetingID: String
    let sourceKind: MeetingAudioTrackKind
    let sourceLabel: String?
    let sessionStartSample: Int64
    let manifest: MeetingAudioManifest
}

private nonisolated struct MeetingAudioTrackArchive: Codable {
    let schemaVersion: Int
    let meetingID: String
    let tracks: [MeetingAudioTrackExport]
}

/// Exports a meeting's original recording. Two shapes:
/// - source archive: the untouched FLAC parts plus manifest.json, zipped, so a
///   recording remains recoverable outside the app;
/// - merged audio: one overlap-free WAV rendered through the logical cursor
///   for convenient listening.
nonisolated enum MeetingAudioExporter {
    private static let logger = Logger(subsystem: "pieroot.todo", category: "MeetingAudioExport")

    private static func operationError(stage: String, error: Error) -> ExportError {
        let diagnostic = error as NSError
        logger.error(
            "Export failure operation=\(stage, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public) description=\(diagnostic.localizedDescription, privacy: .private)"
        )
        DiagnosticRecorder.shared.record(
            error: error,
            component: "meeting.export",
            operation: stage
        )
        return .operation(stage, error)
    }
    /// Archives separate original audio directories, never a mixed WAV. The
    /// catalog's manifests resolve from the archive root with unique namespaces.
    static func exportTrackArchive(
        meetingID: String, tracks: [MeetingAudioTrackExport],
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws -> URL {
        do {
            try MeetingCanonicalID.validateMeetingID(meetingID)
            guard !tracks.isEmpty else { throw ExportError.format }
            let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
            let exports = try makeExportDirectory()
            let staging = exports.appendingPathComponent("meeting-\(meetingID)-tracks", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            defer { try? FileManager.default.removeItem(at: staging) }
            var catalog = [MeetingAudioTrackExport]()
            var ids = Set<String>()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for track in tracks {
                try Task.checkCancellation()
                try MeetingCanonicalID.validateMeetingID(track.meetingID)
                guard track.meetingID != meetingID, ids.insert(track.meetingID).inserted,
                      track.sessionStartSample >= 0,
                      track.manifest.sampleRate == MeetingMediaTimeline.sampleRate,
                      track.manifest.totalSamples > 0,
                      track.manifest.totalSamples <= MeetingMediaTimeline.maximumSamples,
                      track.sessionStartSample <= MeetingMediaTimeline.maximumSamples - track.manifest.totalSamples,
                      !track.manifest.parts.isEmpty,
                      track.manifest.parts.count <= MeetingMediaTimeline.maximumParts,
                      track.manifest.relativeDirectory.hasPrefix("\(track.meetingID)/"),
                      !track.manifest.relativeDirectory.split(separator: "/").contains("..") else {
                    throw ExportError.format
                }
                let source = root.appendingPathComponent(track.manifest.relativeDirectory, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard source.path.hasPrefix(root.appendingPathComponent(track.meetingID).path + "/") else {
                    throw ExportError.format
                }
                let relative = "tracks/\(track.manifest.relativeDirectory)"
                let target = staging.appendingPathComponent(relative, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                var ownedEnd: Int64 = 0
                for (index, part) in track.manifest.parts.sorted(by: { $0.partIndex < $1.partIndex }).enumerated() {
                    try Task.checkCancellation()
                    guard part.partIndex == index, part.fileName == String(format: "part-%02d.flac", index),
                          part.ownedStartSample == ownedEnd, part.ownedEndSample > ownedEnd,
                          part.ownedEndSample <= track.manifest.totalSamples,
                          part.partStartSample == max(0, ownedEnd - MeetingMediaTimeline.overlapSamples),
                          part.ownedEndSample - ownedEnd <= MeetingMediaTimeline.ownedSamplesPerPart else {
                        throw ExportError.format
                    }
                    let original = source.appendingPathComponent(part.fileName).resolvingSymlinksInPath()
                    guard original.path.hasPrefix(source.path + "/") else { throw ExportError.format }
                    let file = try AVAudioFile(forReading: original)
                    guard file.processingFormat.sampleRate == Double(MeetingMediaTimeline.sampleRate),
                          file.processingFormat.channelCount == 1,
                          file.length >= part.ownedEndSample - part.partStartSample else { throw ExportError.format }
                    ownedEnd = part.ownedEndSample
                    try FileManager.default.copyItem(at: original, to: target.appendingPathComponent(part.fileName))
                }
                guard ownedEnd == track.manifest.totalSamples else { throw ExportError.format }
                let manifest = MeetingAudioManifest(relativeDirectory: relative,
                    sampleRate: track.manifest.sampleRate, totalSamples: track.manifest.totalSamples,
                    parts: track.manifest.parts, captureSourceMetadata: track.manifest.captureSourceMetadata)
                try encoder.encode(manifest).write(to: target.appendingPathComponent("manifest.json"))
                catalog.append(MeetingAudioTrackExport(meetingID: track.meetingID, sourceKind: track.sourceKind,
                    sourceLabel: track.sourceLabel, sessionStartSample: track.sessionStartSample, manifest: manifest))
            }
            try encoder.encode(MeetingAudioTrackArchive(schemaVersion: 1, meetingID: meetingID, tracks: catalog))
                .write(to: staging.appendingPathComponent("meeting.json"))
            var coordinatorError: NSError?
            var copyError: Error?
            let zip = exports.appendingPathComponent("meeting-\(meetingID)-tracks.zip")
            NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinatorError) { zipped in
                do { try FileManager.default.copyItem(at: zipped, to: zip) }
                catch { copyError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let copyError { throw copyError }
            return zip
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExportError {
            throw error
        } catch {
            throw operationError(stage: "sourceTracksArchive", error: error)
        }
    }

    static func exportSourceArchive(manifest: MeetingAudioManifest) throws -> URL {
        do {
            return try exportSourceArchiveImpl(manifest: manifest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExportError {
            throw error
        } catch {
            throw operationError(stage: "sourceArchive", error: error)
        }
    }

    private static func exportSourceArchiveImpl(manifest: MeetingAudioManifest) throws -> URL {
        let sourceDirectory = AppDataContainer.meetingDirectory()
            .appendingPathComponent(manifest.relativeDirectory, isDirectory: true)
        let staging = try makeExportDirectory()
            .appendingPathComponent(exportBaseName(manifest), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for part in manifest.parts {
            try Task.checkCancellation()
            try FileManager.default.copyItem(
                at: sourceDirectory.appendingPathComponent(part.fileName),
                to: staging.appendingPathComponent(part.fileName)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        // Coordinated read with .forUploading yields a zipped copy of the
        // directory; it only exists inside the block, so copy it out.
        var coordinatorError: NSError?
        var moveError: Error?
        let zipURL = staging.deletingLastPathComponent()
            .appendingPathComponent("\(exportBaseName(manifest)).zip")
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: zipURL)
            } catch {
                moveError = error
            }
        }
        if let coordinatorError { throw operationError(stage: "zipArchive", error: coordinatorError) }
        if let moveError { throw operationError(stage: "copyArchive", error: moveError) }
        try? FileManager.default.removeItem(at: staging)
        return zipURL
    }

    static func exportMergedAudio(manifest: MeetingAudioManifest) throws -> URL {
        do {
            return try exportMergedAudioImpl(manifest: manifest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExportError {
            throw error
        } catch {
            throw operationError(stage: "mergedAudio", error: error)
        }
    }

    private static func exportMergedAudioImpl(manifest: MeetingAudioManifest) throws -> URL {
        let cursor = try MeetingLogicalAudioCursor(manifest: manifest)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(manifest.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw ExportError.format }
        let url = try makeExportDirectory()
            .appendingPathComponent("\(exportBaseName(manifest)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(manifest.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw operationError(stage: "openOutput", error: error)
        }
        do {
            while let buffer = try cursor.nextPCMBuffer(maxFrames: 65_536, outputFormat: format) {
                try Task.checkCancellation()
                try file.write(from: buffer)
            }
        } catch let error as CancellationError {
            try? FileManager.default.removeItem(at: url)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw operationError(stage: "writeOutput", error: error)
        }
        return url
    }

    private static func makeExportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func exportBaseName(_ manifest: MeetingAudioManifest) -> String {
        let directory = manifest.relativeDirectory
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        return directory.isEmpty ? "meeting-audio" : "meeting-\(directory)"
    }

    enum ExportError: LocalizedError {
        case format
        case operation(String, Error)

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .format:
                return AppLanguage.localized(
                    "error.meeting.export.format",
                    defaultValue: language == .english
                        ? "The original recording export format could not be prepared."
                        : "원본 녹음 내보내기 포맷을 준비할 수 없습니다.",
                    language: language,
                    comment: "Meeting export error shown when the output audio format cannot be prepared."
                )
            case .operation:
                return AppLanguage.localized(
                    "error.meeting.export.operation",
                    defaultValue: language == .english
                        ? "The meeting audio export failed."
                        : "회의 오디오 내보내기에 실패했습니다.",
                    language: language,
                    comment: "Generic meeting export error; stage and provider diagnostics stay in logs."
                )
            }
        }
    }
}
