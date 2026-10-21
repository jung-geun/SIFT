import AVFoundation
import Darwin
import Foundation
import SwiftData

struct PendingMeetingCaptureRecovery: Codable, Identifiable, Sendable {
    let meetingID: String
    let languageTag: String
    let timezoneIdentifier: String
    let manifest: MeetingAudioManifest
    let provisionalResult: MeetingResult
    let errorMessage: String?
    var parentMeetingID: String? = nil
    var sourceKind: MeetingAudioTrackKind? = nil
    var sourceLabel: String? = nil
    var sessionStartSample: Int64? = nil
    var summaryLanguageTag: String? = nil
    var deferredTranscription: Bool? = nil
    var automaticLanguageDetection: Bool = false

    var id: String { meetingID }
}

extension PendingMeetingCaptureRecovery {
    private enum CodingKeys: String, CodingKey {
        case meetingID, languageTag, timezoneIdentifier, manifest, provisionalResult, errorMessage
        case parentMeetingID, sourceKind, sourceLabel, sessionStartSample, summaryLanguageTag, deferredTranscription
        case automaticLanguageDetection
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try values.decode(String.self, forKey: .meetingID)
        languageTag = try values.decode(String.self, forKey: .languageTag)
        timezoneIdentifier = try values.decode(String.self, forKey: .timezoneIdentifier)
        manifest = try values.decode(MeetingAudioManifest.self, forKey: .manifest)
        provisionalResult = try values.decode(MeetingResult.self, forKey: .provisionalResult)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        parentMeetingID = try values.decodeIfPresent(String.self, forKey: .parentMeetingID)
        sourceKind = try values.decodeIfPresent(MeetingAudioTrackKind.self, forKey: .sourceKind)
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        sessionStartSample = try values.decodeIfPresent(Int64.self, forKey: .sessionStartSample)
        summaryLanguageTag = try values.decodeIfPresent(String.self, forKey: .summaryLanguageTag)
        deferredTranscription = try values.decodeIfPresent(Bool.self, forKey: .deferredTranscription)
        automaticLanguageDetection = try values.decodeIfPresent(Bool.self, forKey: .automaticLanguageDetection) ?? false
    }
}

struct MeetingCaptureRecoveryScan: Sendable {
    let recoveries: [PendingMeetingCaptureRecovery]
    let unreadableMarkerNames: [String]
    /// Original native errors for unreadable journals; files and markers stay intact.
    var unreadableMarkerErrors: [String: String] = [:]
}

enum MeetingCaptureRecoveryStore {
    private static let markerName = "capture-recovery.json"

    private static let activeMarkerName = "active-capture.json"

    private struct ActiveCapture: Codable {
        let meetingID: String
        let parentMeetingID: String
        let sourceKind: MeetingAudioTrackKind
        let sourceLabel: String?
        let sessionStartSample: Int64
        let languageTag: String
        let timezoneIdentifier: String
        let relativeDirectory: String
        var summaryLanguageTag: String? = nil
        var deferredTranscription: Bool? = nil
        var automaticLanguageDetection: Bool? = nil
    }

    static func markActive(
        meetingID: String, parentMeetingID: String, sourceKind: MeetingAudioTrackKind,
        sourceLabel: String?, sessionStartSample: Int64, languageTag: String,
        timezoneIdentifier: String, directoryURL: URL, summaryLanguageTag: String? = nil,
        deferredTranscription: Bool = false, automaticLanguageDetection: Bool = false,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        try MeetingCanonicalID.validateMeetingID(meetingID)
        try MeetingCanonicalID.validateMeetingID(parentMeetingID)
        guard try !MeetingDeletionFence.isDeleted(meetingID: meetingID, parentMeetingID: parentMeetingID, rootURL: rootURL) else {
            throw RecoveryError.invalidManifest
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let parent = try meetingDirectory(meetingID: meetingID, rootURL: root)
        let directory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard meetingID != parentMeetingID, sessionStartSample >= 0,
              sessionStartSample < MeetingMediaTimeline.maximumSamples,
              isDescendant(directory, of: parent), isDescendant(parent, of: root) else {
            throw RecoveryError.invalidPath
        }
        let relative = String(directory.path.dropFirst(root.path.count + 1))
        let active = ActiveCapture(meetingID: meetingID, parentMeetingID: parentMeetingID,
            sourceKind: sourceKind, sourceLabel: sourceLabel, sessionStartSample: sessionStartSample,
            languageTag: languageTag, timezoneIdentifier: timezoneIdentifier, relativeDirectory: relative,
            summaryLanguageTag: summaryLanguageTag, deferredTranscription: deferredTranscription,
            automaticLanguageDetection: automaticLanguageDetection)
        try writeMarker(try JSONEncoder().encode(active), name: activeMarkerName, directory: parent)
    }

    @discardableResult
    static func markStopped(
        meetingID: String, audioManifest: MeetingAudioManifest,
        provisionalResult: MeetingResult, errorMessage: String? = nil,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws -> PendingMeetingCaptureRecovery {
        try MeetingCanonicalID.validateMeetingID(meetingID)
        let directory = try meetingDirectory(meetingID: meetingID, rootURL: rootURL)
        let marker = directory.appendingPathComponent(activeMarkerName)
        guard marker.resolvingSymlinksInPath().path == marker.path else { throw RecoveryError.invalidPath }
        try Task.checkCancellation()
        let data = try Data(contentsOf: marker)
        try Task.checkCancellation()
        let active = try JSONDecoder().decode(ActiveCapture.self, from: data)
        guard active.meetingID == meetingID, active.relativeDirectory == audioManifest.relativeDirectory else {
            throw RecoveryError.invalidManifest
        }
        let recovery = PendingMeetingCaptureRecovery(meetingID: meetingID,
            languageTag: active.languageTag, timezoneIdentifier: active.timezoneIdentifier,
            manifest: audioManifest, provisionalResult: provisionalResult, errorMessage: errorMessage,
            parentMeetingID: active.parentMeetingID, sourceKind: active.sourceKind,
            sourceLabel: active.sourceLabel, sessionStartSample: active.sessionStartSample,
            summaryLanguageTag: active.summaryLanguageTag, deferredTranscription: active.deferredTranscription,
            automaticLanguageDetection: active.automaticLanguageDetection ?? false)
        try write(recovery, rootURL: rootURL)
        return recovery
    }

    static func validate(
        _ recovery: PendingMeetingCaptureRecovery,
        markerDirectory: URL,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        try MeetingCanonicalID.validateMeetingID(recovery.meetingID)
        guard try !MeetingDeletionFence.isDeleted(meetingID: recovery.meetingID,
            parentMeetingID: recovery.parentMeetingID, rootURL: rootURL) else { throw RecoveryError.invalidManifest }
        if let parentID = recovery.parentMeetingID {
            try MeetingCanonicalID.validateMeetingID(parentID)
            guard parentID != recovery.meetingID, recovery.sourceKind != nil,
                  recovery.manifest.totalSamples > 0,
                  recovery.manifest.totalSamples <= MeetingMediaTimeline.maximumSamples,
                  let start = recovery.sessionStartSample, start >= 0,
                  start <= MeetingMediaTimeline.maximumSamples - recovery.manifest.totalSamples else {
                throw RecoveryError.invalidManifest
            }
        } else if recovery.sourceKind != nil || recovery.sourceLabel != nil || recovery.sessionStartSample != nil {
            throw RecoveryError.invalidManifest
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = markerDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path == (try meetingDirectory(meetingID: recovery.meetingID, rootURL: root)).path,
              isDescendant(directory, of: root) else {
            throw RecoveryError.invalidPath
        }
        let manifest = recovery.manifest
        let relativeComponents = try relativeAudioComponents(manifest.relativeDirectory, meetingID: recovery.meetingID)
        let audioDirectory = root
            .appendingPathComponent(manifest.relativeDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard manifest.sampleRate == MeetingMediaTimeline.sampleRate,
              manifest.totalSamples > 0, manifest.totalSamples <= MeetingMediaTimeline.maximumSamples,
              !manifest.parts.isEmpty, manifest.parts.count <= MeetingMediaTimeline.maximumParts,
              relativeComponents.count > 1,
              isDescendant(audioDirectory, of: directory) else {
            throw RecoveryError.invalidManifest
        }
        if let sourceMetadata = manifest.captureSourceMetadata {
            var previousSample: Int64 = 0
            for boundary in sourceMetadata.boundaries {
                guard boundary.sample >= previousSample, boundary.sample <= manifest.totalSamples else {
                    throw RecoveryError.invalidManifest
                }
                previousSample = boundary.sample
            }
        }

        let parts = manifest.parts.sorted { $0.partIndex < $1.partIndex }
        var expectedOwnedStart: Int64 = 0
        for (expectedIndex, part) in parts.enumerated() {
            try Task.checkCancellation()
            guard part.partIndex == expectedIndex,
                  part.ownedStartSample == expectedOwnedStart,
                  part.ownedEndSample > part.ownedStartSample,
                  part.ownedEndSample <= manifest.totalSamples,
                  (expectedIndex == parts.count - 1 || part.ownedEndSample - part.ownedStartSample == MeetingMediaTimeline.ownedSamplesPerPart),
                  part.partStartSample == max(0, part.ownedStartSample - MeetingMediaTimeline.overlapSamples),
                  part.ownedEndSample - part.ownedStartSample <= MeetingMediaTimeline.ownedSamplesPerPart,
                  part.fileName == String(format: "part-%02d.flac", expectedIndex)
            else {
                throw RecoveryError.invalidPartMetadata
            }
            let partURL = audioDirectory.appendingPathComponent(part.fileName).standardizedFileURL.resolvingSymlinksInPath()
            guard isDescendant(partURL, of: audioDirectory) else { throw RecoveryError.invalidPath }
            let file = try AVAudioFile(forReading: partURL)
            try Task.checkCancellation()
            let skip = part.ownedStartSample - part.partStartSample
            let owned = part.ownedEndSample - part.ownedStartSample
            guard file.processingFormat.sampleRate == Double(MeetingMediaTimeline.sampleRate),
                  file.processingFormat.channelCount == 1,
                  skip >= 0,
                  file.length >= skip + owned else {
                throw RecoveryError.invalidAudioSamples
            }
            expectedOwnedStart = part.ownedEndSample
        }
        guard expectedOwnedStart == manifest.totalSamples else {
            throw RecoveryError.invalidTotalSamples
        }
        _ = try recovery.provisionalResult.validated()
    }

    static func write(
        _ recovery: PendingMeetingCaptureRecovery,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        let directory = try meetingDirectory(meetingID: recovery.meetingID, rootURL: rootURL)
        try validate(recovery, markerDirectory: directory, rootURL: rootURL)
        try writeMarker(try JSONEncoder().encode(recovery), name: markerName, directory: directory)
    }

    static func scan(
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) -> MeetingCaptureRecoveryScan {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return MeetingCaptureRecoveryScan(recoveries: [], unreadableMarkerNames: [])
        }
        var recoveries = [PendingMeetingCaptureRecovery]()
        var unreadable = [String]()
        var unreadableErrors = [String: String]()
        for directory in directories {
            guard !Task.isCancelled else { break }
            let marker = directory.appendingPathComponent(markerName)
            let activeMarker = directory.appendingPathComponent(activeMarkerName)
            guard FileManager.default.fileExists(atPath: marker.path)
                || FileManager.default.fileExists(atPath: activeMarker.path) else { continue }
            do {
                try Task.checkCancellation()
                let id = directory.lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                if try MeetingDeletionFence.isDeleted(meetingID: id, rootURL: root) {
                    try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: root)
                    continue
                }
                // Resolve the marker before reading identity metadata, not only
                // later during manifest validation.
                let expected = try meetingDirectory(meetingID: id, rootURL: root)
                let source = FileManager.default.fileExists(atPath: marker.path) ? marker : activeMarker
                guard source.resolvingSymlinksInPath().path == source.standardizedFileURL.path,
                      directory.standardizedFileURL.path == expected.path else { throw RecoveryError.invalidPath }
                let data = try Data(contentsOf: source)
                try Task.checkCancellation()
                let parentID = try MeetingDeletionFence.markerParent(data, meetingID: id)
                if try MeetingDeletionFence.isDeleted(meetingID: id, parentMeetingID: parentID, rootURL: root) {
                    try MeetingDeletionFence.recordDeletion(meetingID: id, rootURL: root)
                    try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: root)
                    continue
                }
                let recovery: PendingMeetingCaptureRecovery?
                if FileManager.default.fileExists(atPath: marker.path) {
                    let decoded = try JSONDecoder().decode(PendingMeetingCaptureRecovery.self, from: data)
                    let audio = root.appendingPathComponent(decoded.manifest.relativeDirectory, isDirectory: true)
                    recovery = try MeetingFLACPartWriter.withRecoveryAccess(to: audio) {
                        try validate(decoded, markerDirectory: directory, rootURL: root)
                        return decoded
                    }
                } else {
                    let active = try JSONDecoder().decode(ActiveCapture.self, from: data)
                    let audio = root.appendingPathComponent(active.relativeDirectory, isDirectory: true)
                    recovery = try MeetingFLACPartWriter.withRecoveryAccess(to: audio) {
                        let recovered = try recoverActive(active, directory: directory, rootURL: root)
                        try validate(recovered, markerDirectory: directory, rootURL: root)
                        return recovered
                    }
                }
                // A view can scan before it filters the current capture's ID.
                // Do not decode or report a live writer as a damaged recovery.
                if let recovery { recoveries.append(recovery) }
            } catch is CancellationError {
                break
            } catch {
                unreadable.append(directory.lastPathComponent)
                unreadableErrors[directory.lastPathComponent] = String(reflecting: error)
            }
        }
        return MeetingCaptureRecoveryScan(
            recoveries: recoveries.sorted { $0.meetingID < $1.meetingID },
            unreadableMarkerNames: unreadable.sorted(),
            unreadableMarkerErrors: unreadableErrors
        )
    }

    static func remove(
        meetingID: String,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        try MeetingCanonicalID.validateMeetingID(meetingID)
        let directory = try meetingDirectory(meetingID: meetingID, rootURL: rootURL)
        var removedMarker = false
        for name in [markerName, activeMarkerName] {
            do {
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                removedMarker = true
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
        if removedMarker { try synchronizeDirectory(directory) }
    }

    private static func writeMarker(_ data: Data, name: String, directory: URL) throws {
        let marker = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        var renamed = false
        defer { if !renamed { try? FileManager.default.removeItem(at: temporary) } }
        try Task.checkCancellation()
        try data.write(to: temporary, options: .withoutOverwriting)
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forUpdating: temporary)
        try handle.synchronize()
        try handle.close()
        try Task.checkCancellation()
        guard Darwin.rename(temporary.path, marker.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        try synchronizeDirectory(directory)
    }

    /// A process killed during capture has no final transcript journal. Recover
    /// only physically readable owned frames; never infer speech or pad a tail.
    private static func recoverActive(_ active: ActiveCapture, directory: URL, rootURL: URL) throws -> PendingMeetingCaptureRecovery {
        try Task.checkCancellation()
        let expected = try meetingDirectory(meetingID: active.meetingID, rootURL: rootURL)
        guard directory.standardizedFileURL.path == expected.path else { throw RecoveryError.invalidPath }
        try MeetingCanonicalID.validateMeetingID(active.parentMeetingID)
        guard active.parentMeetingID != active.meetingID, active.sessionStartSample >= 0,
              active.sessionStartSample < MeetingMediaTimeline.maximumSamples else { throw RecoveryError.invalidManifest }
        _ = try relativeAudioComponents(active.relativeDirectory, meetingID: active.meetingID)
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let audio = root.appendingPathComponent(active.relativeDirectory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(audio, of: expected) else { throw RecoveryError.invalidPath }
        let files = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("part-") && $0.pathExtension == "flac" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty, files.count <= MeetingMediaTimeline.maximumParts else { throw RecoveryError.invalidManifest }
        // Reject unsafe names even when an unreadable last file can be ignored.
        for (index, url) in files.enumerated() {
            guard url.lastPathComponent == String(format: "part-%02d.flac", index),
                  isDescendant(url.resolvingSymlinksInPath(), of: audio) else { throw RecoveryError.invalidPartMetadata }
        }
        var parts = [MeetingAudioPartManifest]()
        var ownedStart: Int64 = 0
        var recoveryError: (any Error)?
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            let partStart = max(0, ownedStart - MeetingMediaTimeline.overlapSamples)
            let overlap = ownedStart - partStart
            let limit = min(MeetingMediaTimeline.ownedSamplesPerPart,
                MeetingMediaTimeline.maximumSamples - active.sessionStartSample - ownedStart)
            guard limit > 0 else { break }
            let readable: (samples: Int64, failure: (any Error)?)
            do {
                readable = try readableSamples(at: url, limit: overlap + limit)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recoveryError = error
                break
            }
            recoveryError = readable.failure
            let owned = readable.samples - overlap
            guard owned > 0 else {
                recoveryError = recoveryError ?? RecoveryError.invalidAudioSamples
                break
            }
            parts.append(MeetingAudioPartManifest(fileName: url.lastPathComponent, partIndex: index,
                partStartSample: partStart, ownedStartSample: ownedStart, ownedEndSample: ownedStart + owned))
            ownedStart += owned
            // Later parts begin at fixed writer boundaries. Do not splice
            // speech across a partial or missing owned range.
            if recoveryError != nil || owned < MeetingMediaTimeline.ownedSamplesPerPart { break }
        }
        guard !parts.isEmpty else { throw recoveryError ?? RecoveryError.invalidAudioSamples }
        let manifest = MeetingAudioManifest(relativeDirectory: active.relativeDirectory,
            sampleRate: MeetingMediaTimeline.sampleRate, totalSamples: ownedStart, parts: parts)
        return PendingMeetingCaptureRecovery(meetingID: active.meetingID,
            languageTag: active.languageTag, timezoneIdentifier: active.timezoneIdentifier,
            manifest: manifest,
            provisionalResult: MeetingProvisionalResultBuilder.make(meetingID: active.meetingID, entries: []),
            errorMessage: recoveryError.map { String(reflecting: $0) },
            parentMeetingID: active.parentMeetingID, sourceKind: active.sourceKind,
            sourceLabel: active.sourceLabel, sessionStartSample: active.sessionStartSample,
            summaryLanguageTag: active.summaryLanguageTag, deferredTranscription: active.deferredTranscription,
            automaticLanguageDetection: active.automaticLanguageDetection ?? false)
    }

    private static func readableSamples(at url: URL, limit: Int64) throws -> (samples: Int64, failure: (any Error)?) {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        guard file.processingFormat.sampleRate == Double(MeetingMediaTimeline.sampleRate),
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
            throw RecoveryError.invalidAudioSamples
        }
        let end = min(file.length, limit)
        var decoded: Int64 = 0
        while decoded < end {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), end - decoded))
            do {
                try file.read(into: buffer, frameCount: count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (decoded, error)
            }
            try Task.checkCancellation()
            guard buffer.frameLength > 0 else { return (decoded, RecoveryError.invalidAudioSamples) }
            decoded += Int64(buffer.frameLength)
            if buffer.frameLength < count { return (decoded, RecoveryError.invalidAudioSamples) }
        }
        return (decoded, nil)
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func meetingDirectory(meetingID: String, rootURL: URL) throws -> URL {
        try MeetingCanonicalID.validateMeetingID(meetingID)
        guard rootURL.isFileURL else { throw RecoveryError.invalidPath }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let expected = root.appendingPathComponent(meetingID, isDirectory: true).standardizedFileURL
        guard expected.resolvingSymlinksInPath().path == expected.path else { throw RecoveryError.invalidPath }
        return expected
    }

    private static func relativeAudioComponents(_ relative: String, meetingID: String) throws -> [String] {
        let components = relative.components(separatedBy: "/")
        guard components.count > 1, components.first == meetingID,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecoveryError.invalidPath
        }
        return components
    }

    /// Artifacts carry their audio URL so temporary-root tests use the same
    /// ownership checks as production without another persistence API.
    static func validate(track: MeetingCaptureTrackArtifact, parentMeetingID: String,
                         languageTag: String, timezoneIdentifier: String) throws -> URL {
        let components = try relativeAudioComponents(track.audioManifest.relativeDirectory, meetingID: track.meetingID)
        guard track.directoryURL.isFileURL else { throw RecoveryError.invalidPath }
        let directory = track.directoryURL.standardizedFileURL
        var root = directory
        for component in components.reversed() {
            guard root.lastPathComponent == component else { throw RecoveryError.invalidPath }
            root.deleteLastPathComponent()
        }
        let recovery = PendingMeetingCaptureRecovery(meetingID: track.meetingID,
            languageTag: languageTag, timezoneIdentifier: timezoneIdentifier,
            manifest: track.audioManifest, provisionalResult: track.provisionalResult, errorMessage: nil,
            parentMeetingID: parentMeetingID, sourceKind: track.sourceKind,
            sourceLabel: track.sourceLabel, sessionStartSample: track.sessionStartSample)
        try validate(recovery, markerDirectory: root.appendingPathComponent(track.meetingID), rootURL: root)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path.hasPrefix(parentPath)
    }

    enum RecoveryError: LocalizedError {
        case invalidPath
        case invalidManifest
        case invalidPartMetadata
        case invalidAudioSamples
        case invalidTotalSamples

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .invalidPath:
                return AppLanguage.localized(
                    "error.meeting.captureRecovery.invalidPath",
                    defaultValue: language == .english
                        ? "The recording file path to recover is invalid."
                        : "복구할 녹음 파일 경로가 올바르지 않습니다.",
                    language: language,
                    comment: "Meeting capture recovery error shown when the recording file path is invalid."
                )
            case .invalidManifest, .invalidPartMetadata, .invalidAudioSamples, .invalidTotalSamples:
                return AppLanguage.localized(
                    "error.meeting.captureRecovery.invalidManifest",
                    defaultValue: language == .english
                        ? "The recording manifest to recover is invalid."
                        : "복구할 녹음 manifest가 올바르지 않습니다.",
                    language: language,
                    comment: "Meeting capture recovery error shown when the recording manifest is invalid."
                )
            }
        }
    }
}

enum MeetingProvisionalResultBuilder {
    static func make(
        meetingID: String,
        entries: [LiveTranscriptEntry]
    ) -> MeetingResult {
        var rawSegments = [MeetingSegment]()
        for entry in entries {
            let startMs = max(0, entry.startMs)
            let endMs = max(startMs + 1, entry.endMs)
            let sanitizedRuns = sanitizeTimedRuns(
                entry.timedRuns,
                segmentStartMs: startMs,
                segmentEndMs: endMs,
                text: entry.text
            )
            let segment = MeetingSegment(
                id: MeetingCanonicalID.replacementSegment(
                    meetingID: meetingID,
                    transcriptRevision: 0,
                    startMs: startMs,
                    endMs: endMs,
                    text: entry.text
                ),
                startMs: startMs,
                endMs: endMs,
                // Live labels are tentative; only full saved-audio inference may persist them.
                speakerIDs: [],
                text: entry.text,
                isFinal: entry.isFinal,
                confidence: entry.confidence,
                timedRuns: sanitizedRuns
            )
            guard segment.isValid else { continue }
            rawSegments.append(segment)
        }

        rawSegments.sort {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
            return $0.id < $1.id
        }

        var seenIDs = Set<String>()
        var seenLineages = Set<String>()
        var previousOrder: (Int64, Int64, String)?
        var validSegments = [MeetingSegment]()

        for segment in rawSegments {
            guard !seenIDs.contains(segment.id),
                  !seenLineages.contains(segment.stableLineageID) else { continue }
            if let previous = previousOrder, (segment.startMs, segment.endMs, segment.id) <= previous {
                continue
            }
            seenIDs.insert(segment.id)
            seenLineages.insert(segment.stableLineageID)
            previousOrder = (segment.startMs, segment.endMs, segment.id)
            validSegments.append(segment)
        }

        return MeetingResult(segments: validSegments)
    }

    private static func sanitizeTimedRuns(
        _ runs: [MeetingTimedTextRun]?,
        segmentStartMs: Int64,
        segmentEndMs: Int64,
        text: String
    ) -> [MeetingTimedTextRun]? {
        guard let runs, !runs.isEmpty, segmentEndMs > segmentStartMs else { return nil }
        let textLength = text.utf16.count
        guard textLength > 0 else { return nil }

        var sanitized = [MeetingTimedTextRun]()
        var previousOffset = 0
        var previousTime = segmentStartMs

        for run in runs {
            guard run.utf16Offset >= previousOffset,
                  run.utf16Length > 0,
                  run.utf16Offset < textLength,
                  run.utf16Offset + run.utf16Length <= textLength else { continue }

            let start = max(previousTime, max(segmentStartMs, run.startMs))
            let end = min(segmentEndMs, max(start + 1, run.endMs))
            guard end > start, start >= previousTime, end <= segmentEndMs else { continue }

            sanitized.append(MeetingTimedTextRun(
                utf16Offset: run.utf16Offset,
                utf16Length: run.utf16Length,
                startMs: start,
                endMs: end
            ))
            previousOffset = run.utf16Offset + run.utf16Length
            previousTime = end
        }
        return sanitized.isEmpty ? nil : sanitized
    }
}

@MainActor
enum MeetingCaptureRecoveryPersister {
    static func persist(
        _ recovery: PendingMeetingCaptureRecovery,
        in context: ModelContext,
        rootURL: URL = AppDataContainer.meetingDirectory(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try Task.checkCancellation()
        if try MeetingDeletionFence.isDeleted(meetingID: recovery.meetingID,
            parentMeetingID: recovery.parentMeetingID, rootURL: rootURL) {
            // A cached recovery may predate the tombstone even when its marker
            // has already been removed by a foreground scan.
            try MeetingDeletionFence.recordDeletion(meetingID: recovery.meetingID, rootURL: rootURL)
            try MeetingDeletionFence.removeDeletedContent(meetingID: recovery.meetingID, rootURL: rootURL)
            return
        }
        let directory = rootURL.appendingPathComponent(recovery.meetingID, isDirectory: true)
        try MeetingCaptureRecoveryStore.validate(recovery, markerDirectory: directory, rootURL: rootURL)
        let descriptor = FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.meetingID == recovery.meetingID }
        )
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else { throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest }
        let existing = matches.first
        if let existing {
            guard existing.parentMeetingID == recovery.parentMeetingID,
                  existing.audioTrackIDs.isEmpty,
                  existing.audioManifest == recovery.manifest,
                  (recovery.parentMeetingID == nil ||
                    (existing.audioTrackKind == recovery.sourceKind &&
                     existing.audioTrackStartSample == recovery.sessionStartSample)) else {
                throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest
            }
        }
        let committed = existing.map { isCommittedPhaseTwo($0, matching: recovery.manifest) } ?? false
        if committed, recovery.parentMeetingID == nil {
            try MeetingCaptureRecoveryStore.remove(meetingID: recovery.meetingID, rootURL: rootURL)
            return
        }

        let record: MeetingRecord
        let inserted: Bool
        if let existing {
            record = existing
            inserted = false
        } else {
            record = MeetingRecord(
                meetingID: recovery.meetingID,
                languageTag: recovery.languageTag,
                automaticLanguageDetection: recovery.automaticLanguageDetection,
                timezoneIdentifier: recovery.timezoneIdentifier,
                summaryLanguageTag: recovery.summaryLanguageTag ?? ""
            )
            context.insert(record)
            inserted = true
        }
        let childSnapshot = record.persistenceSnapshot()
        let parent: MeetingRecord?
        let insertedParent: Bool
        do {
            if let parentID = recovery.parentMeetingID {
                let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == parentID })
                let parents = try context.fetch(descriptor)
                guard parents.count <= 1 else { throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest }
                if let existingParent = parents.first {
                    _ = try MeetingAudioTrackStore.tracks(for: existingParent, in: context)
                    parent = existingParent
                    insertedParent = false
                } else {
                    let group = MeetingRecord(meetingID: parentID, languageTag: recovery.languageTag,
                                              automaticLanguageDetection: recovery.automaticLanguageDetection,
                                              timezoneIdentifier: recovery.timezoneIdentifier,
                                              summaryLanguageTag: recovery.summaryLanguageTag ?? "")
                    context.insert(group)
                    parent = group
                    insertedParent = true
                }
            } else {
                parent = nil
                insertedParent = false
            }
        } catch {
            if inserted { context.delete(record) }
            throw error
        }
        let parentSnapshot = parent?.persistenceSnapshot()

        do {
            if !committed {
                try record.replaceTranscriptionBase(recovery.provisionalResult, status: .transcriptFinalizationFailed,
                    source: recovery.deferredTranscription == true || recovery.automaticLanguageDetection ? .savedAudio : .apple)
                try record.update(audioManifest: recovery.manifest)
            }
            if let parent {
                if !committed {
                    record.parentMeetingID = parent.meetingID
                    record.audioTrackKindRaw = recovery.sourceKind?.rawValue
                    record.audioTrackSourceLabel = recovery.sourceLabel
                    record.audioTrackStartSample = recovery.sessionStartSample ?? 0
                }
                if !parent.audioTrackIDs.contains(record.meetingID) { parent.audioTrackIDs.append(record.meetingID) }
                try MeetingAudioTrackStore.refresh(parent: parent, in: context, save: save)
            } else {
                try save(context)
            }
        } catch {
            record.restore(childSnapshot)
            if let parent, let parentSnapshot { parent.restore(parentSnapshot) }
            if inserted { context.delete(record) }
            if insertedParent, let parent { context.delete(parent) }
            throw error
        }
        try MeetingCaptureRecoveryStore.remove(
            meetingID: recovery.meetingID,
            rootURL: rootURL
        )
    }

    private static func isCommittedPhaseTwo(
        _ record: MeetingRecord,
        matching manifest: MeetingAudioManifest
    ) -> Bool {
        // Completed legacy rows need not have raw snapshots. A durably failed
        // Apple base also outranks the older audio-stop journal's provisional text.
        let committed = record.status == .ready || (record.status == .transcriptFinalizationFailed
            && record.rawResult != nil && record.appleRawResult != nil)
        return committed && record.audioManifest == manifest && record.result != nil
    }
}

@MainActor
enum MeetingInitialCapturePersister {
    static func persist(
        artifact: MeetingCaptureArtifact,
        languageTag: String, timezoneIdentifier: String, summaryLanguageTag: String = "", deferredTranscription: Bool = false,
        automaticLanguageDetection: Bool = false,
        in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> MeetingRecord {
        let awaitsOfflineTranscription = deferredTranscription || automaticLanguageDetection
        try MeetingCanonicalID.validateMeetingID(artifact.meetingID)
        guard !artifact.tracks.isEmpty else { throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest }
        var namespaces: Set<String> = [artifact.meetingID]
        var root: URL?
        for track in artifact.tracks {
            guard namespaces.insert(track.meetingID).inserted else {
                throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest
            }
            let trackRoot = try MeetingCaptureRecoveryStore.validate(track: track,
                parentMeetingID: artifact.meetingID, languageTag: languageTag, timezoneIdentifier: timezoneIdentifier)
            if let root, root != trackRoot { throw MeetingCaptureRecoveryStore.RecoveryError.invalidPath }
            root = trackRoot
        }
        // SwiftData does not enforce unique meeting IDs. Reject all occupied
        // namespaces before inserting, rather than relying on a save upsert.
        for id in namespaces {
            if let root {
                guard try !MeetingDeletionFence.isDeleted(meetingID: id, rootURL: root) else {
                    throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest
                }
            }
            let existing = try context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id }))
            guard existing.isEmpty else { throw MeetingCaptureRecoveryStore.RecoveryError.invalidManifest }
        }
        let parent = MeetingRecord(meetingID: artifact.meetingID,
            languageTag: languageTag, automaticLanguageDetection: automaticLanguageDetection,
            timezoneIdentifier: timezoneIdentifier, summaryLanguageTag: summaryLanguageTag)
        var inserted = [MeetingRecord]()
        context.insert(parent)
        do {
            for track in artifact.tracks {
                let child = MeetingRecord(meetingID: track.meetingID,
                    languageTag: languageTag, automaticLanguageDetection: automaticLanguageDetection,
                    timezoneIdentifier: timezoneIdentifier, summaryLanguageTag: summaryLanguageTag)
                context.insert(child)
                inserted.append(child)
                child.parentMeetingID = parent.meetingID
                child.audioTrackKindRaw = track.sourceKind.rawValue
                child.audioTrackSourceLabel = track.sourceLabel
                child.audioTrackStartSample = track.sessionStartSample
                try child.replaceTranscriptionBase(track.provisionalResult,
                    status: awaitsOfflineTranscription ? .transcriptFinalizationFailed : .finalizingTranscript,
                    source: awaitsOfflineTranscription ? .savedAudio : .apple)
                try child.update(audioManifest: track.audioManifest)
                parent.audioTrackIDs.append(child.meetingID)
            }
            try MeetingAudioTrackStore.refresh(parent: parent, in: context, save: save)
            return parent
        } catch {
            for child in inserted { context.delete(child) }
            context.delete(parent)
            throw error
        }
    }
}

@MainActor
enum MeetingCaptureTranscriptPersister {
    /// A superseded child keeps its edited transcript and becomes usable; only
    /// the separate Apple source snapshot may advance when finalization ends.
    @discardableResult
    static func persist(
        record: MeetingRecord, baseline: MeetingResult, failed: Bool,
        expectedResultData: Data, in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Bool {
        let id = record.meetingID
        guard let latest = try context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })).first,
              latest.persistentModelID == record.persistentModelID,
              record.status == .finalizingTranscript else { return false }
        let base = try baseline.validated()
        if record.resultData != expectedResultData {
            try MeetingRecordCommitter.persist(record: record, save: { try save(context) }) {
                record.appleRawResultData = try JSONEncoder().encode(base)
                record.update(status: .ready)
            }
            return false
        }
        try MeetingRecordCommitter.persist(record: record, save: { try save(context) }) {
            try record.replaceTranscriptionBase(base, status: failed ? .transcriptFinalizationFailed : .ready)
        }
        return true
    }
}
