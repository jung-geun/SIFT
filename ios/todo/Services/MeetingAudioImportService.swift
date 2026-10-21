@preconcurrency import AVFoundation
import Darwin
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Files-app import only: no microphone session, Speech authorization, network
/// upload, or model download. The caller starts saved-audio ASR after commit.
nonisolated enum MeetingAudioImportService {
    static let allowedContentTypes: [UTType] = [.audio]
    static let bufferFrames: AVAudioFrameCount = 4_096

    enum Failure: LocalizedError, Equatable {
        case unavailableInput, unsupportedAudio, emptyAudio, decodeFailed
        case durationLimit, storageFailed, cleanupFailed

        var errorDescription: String? { errorDescription(language: .current) }

        func errorDescription(language: AppLanguage) -> String {
            let key: String
            let english: String
            switch self {
            case .unavailableInput:
                key = "meeting.audioImport.error.unavailableInput"
                english = "The selected file is unavailable or unreadable. Download it in Files and select it again."
            case .unsupportedAudio:
                key = "meeting.audioImport.error.unsupportedAudio"
                english = "This file cannot be decoded as audio on this device. Try WAV, M4A, MP3, AIFF, CAF, or FLAC."
            case .emptyAudio:
                key = "meeting.audioImport.error.emptyAudio"
                english = "The selected file contains no audio frames."
            case .decodeFailed:
                key = "meeting.audioImport.error.decodeFailed"
                english = "Audio decoding stopped before the file was complete. No meeting was imported."
            case .durationLimit:
                key = "meeting.audioImport.error.durationLimit"
                english = "Audio imports are limited to six hours."
            case .storageFailed:
                key = "meeting.audioImport.error.storageFailed"
                english = "The imported recording could not be saved. Check available device storage and try again."
            case .cleanupFailed:
                key = "meeting.audioImport.error.cleanupFailed"
                english = "Import stopped, but its new local files could not be removed. The original file was not changed."
            }
            return AppLanguage.localized(key, defaultValue: english, language: language,
                                         comment: "Audio file import error; the original file is unchanged.")
        }
    }

    /// Progress is a bounded sequence (at most 101 updates), delivered on the
    /// worker, and reaches 1 only after the database commit on the main actor.
    @MainActor
    static func importFile(
        at sourceURL: URL,
        languageTag: String,
        automaticLanguageDetection: Bool = false,
        timezoneIdentifier: String = TimeZone.current.identifier,
        summaryLanguageTag: String = "",
        in context: ModelContext,
        rootURL: URL = AppDataContainer.meetingDirectory(),
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) async throws -> MeetingRecord {
        // Automatic mode keeps the locale for summaries, not as a decoder hint.
        if !automaticLanguageDetection {
            _ = try MeetingOfflineTranscriptionService.languageCode(for: languageTag)
        }
        try Task.checkCancellation()
        let id = UUID().uuidString.lowercased()
        let coordinatedRead = CoordinatedRead()
        let worker = Task.detached(priority: .userInitiated) {
            try prepare(sourceURL: sourceURL, meetingID: id, rootURL: rootURL,
                        coordinatedRead: coordinatedRead, progress: progress)
        }
        let artifact = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            coordinatedRead.coordinator.cancel()
        }
        // The worker transfers ownership only on success. No suspension between
        // the final cancellation check and save: commit wins once save succeeds.
        do {
            try Task.checkCancellation()
            let occupied = try context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id }))
            guard occupied.isEmpty else { throw Failure.storageFailed }
            let record = MeetingRecord(meetingID: id, languageTag: languageTag,
                automaticLanguageDetection: automaticLanguageDetection,
                timezoneIdentifier: timezoneIdentifier, summaryLanguageTag: summaryLanguageTag)
            record.importedAudioFileName = sourceURL.lastPathComponent
            let title = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            try record.replaceTranscriptionBase(
                MeetingResult(title: title.isEmpty ? sourceURL.lastPathComponent : title),
                status: .transcriptFinalizationFailed, source: .importedAudio
            )
            try record.update(audioManifest: artifact.manifest)
            context.insert(record)
            do { try save(context) }
            catch {
                // Never rollback the caller's other pending changes.
                context.delete(record)
                throw Failure.storageFailed
            }
            progress(1)
            return record
        } catch {
            try removeOwnedDirectory(artifact.directory)
            throw error
        }
    }

    private struct Artifact: Sendable {
        let directory: URL
        let manifest: MeetingAudioManifest
    }

    /// NSFileCoordinator.cancel() may be called from the cancelling task while
    /// its worker waits on a file provider. No other state crosses threads.
    private final class CoordinatedRead: @unchecked Sendable {
        let coordinator = NSFileCoordinator()
    }

    private static func prepare(
        sourceURL: URL, meetingID: String, rootURL: URL,
        coordinatedRead: CoordinatedRead,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Artifact {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw Failure.unavailableInput }
        // A fresh exclusive directory is the sole deletion authority. Existing
        // namespaces (including symlinks) are never opened or cleaned by import.
        let directory = rootURL.appendingPathComponent(meetingID, isDirectory: true)
        guard mkdir(directory.path, S_IRWXU) == 0 else { throw Failure.storageFailed }
        do {
            try protect(directory)
            var coordinationError: NSError?
            var outcome: Result<MeetingAudioManifest, Error>?
            coordinatedRead.coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { readableURL in
                outcome = Result {
                    try Task.checkCancellation()
                    guard (try? readableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                          FileManager.default.isReadableFile(atPath: readableURL.path) else {
                        throw Failure.unavailableInput
                    }
                    return try decode(sourceURL: readableURL, directory: directory,
                                      relativeDirectory: "\(meetingID)/audio", progress: progress)
                }
            }
            try Task.checkCancellation()
            guard coordinationError == nil, let outcome else { throw Failure.unavailableInput }
            let manifest = try outcome.get()
            try Task.checkCancellation()
            return Artifact(directory: directory, manifest: manifest)
        } catch {
            try removeOwnedDirectory(directory)
            throw error
        }
    }

    private static func decode(
        sourceURL: URL, directory: URL, relativeDirectory: String,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> MeetingAudioManifest {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw Failure.unsupportedAudio }
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferFrames) else {
            throw Failure.unsupportedAudio
        }
        guard file.length > 0 else { throw Failure.emptyAudio }
        guard Double(file.length) / format.sampleRate <= Double(MeetingMediaTimeline.maximumSamples) / 16_000 else {
            throw Failure.durationLimit
        }
        let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        let writer: MeetingFLACPartWriter
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: false)
            try protect(audioDirectory)
            writer = try MeetingFLACPartWriter(directory: audioDirectory)
        } catch { throw Failure.storageFailed }
        var lastPercent = -1
        while true {
            try Task.checkCancellation()
            let positionBefore = file.framePosition
            let status: AVAudioConverterOutputStatus = try autoreleasepool {
                var conversionError: NSError?
                var readError: Error?
                let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                    do {
                        try Task.checkCancellation()
                        let remaining = file.length - file.framePosition
                        guard remaining > 0 else {
                            inputStatus.pointee = .endOfStream
                            return nil
                        }
                        let frames = AVAudioFrameCount(min(Int64(bufferFrames), Int64(requested), remaining))
                        guard frames > 0 else { throw Failure.decodeFailed }
                        try file.read(into: input, frameCount: frames)
                        guard input.frameLength > 0 else { throw Failure.decodeFailed }
                        inputStatus.pointee = .haveData
                        return input
                    } catch {
                        readError = error
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError {
                    if readError is CancellationError { throw CancellationError() }
                    throw Failure.decodeFailed
                }
                guard conversionError == nil, status != .error else { throw Failure.decodeFailed }
                if output.frameLength > 0 {
                    do { try writer.append(output) }
                    catch MeetingFLACPartWriterError.durationLimit { throw Failure.durationLimit }
                    catch { throw Failure.storageFailed }
                }
                return status
            }
            let percent = min(99, Int(Double(file.framePosition) / Double(file.length) * 100))
            if percent > lastPercent { lastPercent = percent; progress(Double(percent) / 100) }
            if status == .endOfStream { break }
            guard output.frameLength > 0 || file.framePosition > positionBefore else { throw Failure.decodeFailed }
        }
        guard file.framePosition == file.length else { throw Failure.decodeFailed }
        guard writer.totalSamples > 0 else { throw Failure.emptyAudio }
        do { _ = try writer.finish() }
        catch { throw Failure.storageFailed }
        let manifest = writer.manifest(relativeDirectory: relativeDirectory)
        // Validate finalized physical files, not just metadata. The same cursor
        // then serves playback, export and Whisper without an import-only path.
        for part in manifest.parts {
            try Task.checkCancellation()
            let decoded = try AVAudioFile(forReading: audioDirectory.appendingPathComponent(part.fileName))
            guard decoded.processingFormat.sampleRate == 16_000,
                  decoded.processingFormat.channelCount == 1,
                  decoded.length == part.ownedEndSample - part.partStartSample else { throw Failure.decodeFailed }
            try protect(audioDirectory.appendingPathComponent(part.fileName))
        }
        return manifest
    }

    private static func protect(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private static func removeOwnedDirectory(_ directory: URL) throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw Failure.cleanupFailed }
    }
}
