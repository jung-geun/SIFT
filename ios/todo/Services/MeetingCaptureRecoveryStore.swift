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

    var id: String { meetingID }
}

struct MeetingCaptureRecoveryScan: Sendable {
    let recoveries: [PendingMeetingCaptureRecovery]
    let unreadableMarkerNames: [String]
}

enum MeetingCaptureRecoveryStore {
    private static let markerName = "capture-recovery.json"

    static func validate(
        _ recovery: PendingMeetingCaptureRecovery,
        markerDirectory: URL,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        try MeetingCanonicalID.validateMeetingID(recovery.meetingID)
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = markerDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.lastPathComponent == recovery.meetingID,
              isDescendant(directory, of: root) else {
            throw RecoveryError.invalidPath
        }
        let manifest = recovery.manifest
        let relativeComponents = manifest.relativeDirectory.split(separator: "/")
        let audioDirectory = root
            .appendingPathComponent(manifest.relativeDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard manifest.sampleRate == MeetingMediaTimeline.sampleRate,
              manifest.totalSamples > 0,
              !manifest.parts.isEmpty,
              !relativeComponents.isEmpty,
              !relativeComponents.contains(".."),
              isDescendant(audioDirectory, of: directory) else {
            throw RecoveryError.invalidManifest
        }

        let parts = manifest.parts.sorted { $0.partIndex < $1.partIndex }
        var expectedOwnedStart: Int64 = 0
        for (expectedIndex, part) in parts.enumerated() {
            guard part.partIndex == expectedIndex,
                  part.ownedStartSample == expectedOwnedStart,
                  part.ownedEndSample > part.ownedStartSample,
                  part.partStartSample == max(0, part.ownedStartSample - MeetingMediaTimeline.overlapSamples),
                  part.ownedEndSample - part.ownedStartSample <= MeetingMediaTimeline.ownedSamplesPerPart,
                  part.fileName == String(format: "part-%02d.flac", expectedIndex)
            else {
                throw RecoveryError.invalidManifest
            }
            let partURL = audioDirectory.appendingPathComponent(part.fileName).standardizedFileURL.resolvingSymlinksInPath()
            guard isDescendant(partURL, of: directory) else { throw RecoveryError.invalidPath }
            let file = try AVAudioFile(forReading: partURL)
            let skip = part.ownedStartSample - part.partStartSample
            let owned = part.ownedEndSample - part.ownedStartSample
            guard file.processingFormat.sampleRate == Double(MeetingMediaTimeline.sampleRate),
                  file.processingFormat.channelCount == 1,
                  skip >= 0,
                  file.length >= skip + owned else {
                throw RecoveryError.invalidManifest
            }
            expectedOwnedStart = part.ownedEndSample
        }
        guard expectedOwnedStart == manifest.totalSamples,
              (try? recovery.provisionalResult.validated()) != nil else {
            throw RecoveryError.invalidManifest
        }
    }

    static func write(
        _ recovery: PendingMeetingCaptureRecovery,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        let directory = rootURL.appendingPathComponent(recovery.meetingID, isDirectory: true)
        try validate(recovery, markerDirectory: directory, rootURL: rootURL)
        let marker = directory.appendingPathComponent(markerName)
        let temporary = directory.appendingPathComponent(".\(markerName).\(UUID().uuidString).tmp")
        var renamed = false
        defer {
            if !renamed { try? FileManager.default.removeItem(at: temporary) }
        }
        let data = try JSONEncoder().encode(recovery)
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forUpdating: temporary)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, marker.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        try synchronizeDirectory(directory)
    }

    static func scan(
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) -> MeetingCaptureRecoveryScan {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return MeetingCaptureRecoveryScan(recoveries: [], unreadableMarkerNames: [])
        }
        var recoveries = [PendingMeetingCaptureRecovery]()
        var unreadable = [String]()
        for directory in directories {
            let marker = directory.appendingPathComponent(markerName)
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            do {
                let recovery = try JSONDecoder().decode(PendingMeetingCaptureRecovery.self, from: Data(contentsOf: marker))
                try validate(recovery, markerDirectory: directory, rootURL: rootURL)
                recoveries.append(recovery)
            } catch {
                unreadable.append(directory.lastPathComponent)
            }
        }
        return MeetingCaptureRecoveryScan(
            recoveries: recoveries.sorted { $0.meetingID < $1.meetingID },
            unreadableMarkerNames: unreadable.sorted()
        )
    }

    static func remove(
        meetingID: String,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        try MeetingCanonicalID.validateMeetingID(meetingID)
        let marker = rootURL.appendingPathComponent(meetingID, isDirectory: true).appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.removeItem(at: marker)
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path.hasPrefix(parentPath)
    }

    enum RecoveryError: LocalizedError {
        case invalidPath
        case invalidManifest

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
            case .invalidManifest:
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
        entries: [LiveTranscriptEntry],
        elapsedMediaMs: Int64
    ) -> MeetingResult {
        let fallbackEnd = max(Int64(1), elapsedMediaMs)
        let source = entries.isEmpty
            ? [LiveTranscriptEntry(id: "whole", startMs: 0, endMs: fallbackEnd, text: "", speakerIDs: [])]
            : entries
        return MeetingResult(segments: source.map { entry in
            let endMs = max(entry.startMs + 1, entry.endMs)
            return MeetingSegment(
                id: MeetingCanonicalID.replacementSegment(
                    meetingID: meetingID,
                    transcriptRevision: 0,
                    startMs: entry.startMs,
                    endMs: endMs,
                    text: entry.text
                ),
                startMs: entry.startMs,
                endMs: endMs,
                speakerIDs: entry.speakerIDs,
                text: entry.text,
                isFinal: entry.isFinal,
                confidence: entry.confidence
            )
        })
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
        let directory = rootURL.appendingPathComponent(recovery.meetingID, isDirectory: true)
        try MeetingCaptureRecoveryStore.validate(recovery, markerDirectory: directory, rootURL: rootURL)
        let descriptor = FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.meetingID == recovery.meetingID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, isCommittedPhaseTwo(existing, matching: recovery.manifest) {
            try MeetingCaptureRecoveryStore.remove(
                meetingID: recovery.meetingID,
                rootURL: rootURL
            )
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
                timezoneIdentifier: recovery.timezoneIdentifier
            )
            context.insert(record)
            inserted = true
        }

        do {
            try MeetingRecordCommitter.persist(
                record: record,
                save: { try save(context) },
                mutate: {
                    try record.replaceTranscriptionBase(
                        recovery.provisionalResult,
                        status: .transcriptFinalizationFailed
                    )
                    try record.update(audioManifest: recovery.manifest)
                }
            )
        } catch {
            if inserted { context.delete(record) }
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
        guard record.status == .ready,
              record.audioManifest == manifest,
              let raw = record.rawResult,
              let result = record.result
        else { return false }
        return result.transcriptRevision >= raw.transcriptRevision
    }
}

@MainActor
enum MeetingInitialCapturePersister {
    static func persist(
        meetingID: String,
        languageTag: String,
        timezoneIdentifier: String,
        provisionalResult: MeetingResult,
        manifest: MeetingAudioManifest,
        in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> MeetingRecord {
        let record = MeetingRecord(
            meetingID: meetingID,
            languageTag: languageTag,
            timezoneIdentifier: timezoneIdentifier
        )
        context.insert(record)
        do {
            try MeetingRecordCommitter.persist(
                record: record,
                save: { try save(context) },
                mutate: {
                    try record.update(result: provisionalResult, status: .finalizingTranscript)
                    try record.update(audioManifest: manifest)
                }
            )
            return record
        } catch {
            context.delete(record)
            throw error
        }
    }
}

@MainActor
enum MeetingFinalizationFailurePersister {
    static func persist(
        record: MeetingRecord,
        in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try MeetingRecordCommitter.persist(
            record: record,
            save: { try save(context) },
            mutate: { record.update(status: .transcriptFinalizationFailed) }
        )
    }
}
