import AVFoundation
import Foundation
import os

/// Exports a meeting's original recording. Two shapes:
/// - source archive: the untouched FLAC parts plus manifest.json, zipped, so a
///   recording remains recoverable outside the app;
/// - merged audio: one overlap-free WAV rendered through the logical cursor
///   for convenient listening.
enum MeetingAudioExporter {
    private static let logger = Logger(subsystem: "pieroot.todo", category: "MeetingAudioExport")

    private static func operationError(stage: String, error: Error) -> ExportError {
        let diagnostic = error as NSError
        logger.error(
            "Export failure operation=\(stage, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public) description=\(diagnostic.localizedDescription, privacy: .private)"
        )
        return .operation(stage, error)
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
