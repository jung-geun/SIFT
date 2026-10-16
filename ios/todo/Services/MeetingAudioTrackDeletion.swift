import Foundation
import SwiftData

/// The database and recovery journals stop owning the audio before files are
/// removed. A failed save never destroys a retained record's original audio.
@MainActor
enum MeetingAudioTrackDeletion {
    static func delete(
        parent: MeetingRecord, in context: ModelContext,
        rootURL: URL = AppDataContainer.meetingDirectory(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let children = parent.isAudioTrackGroup ? try MeetingAudioTrackStore.tracks(for: parent, in: context) : []
        let records = children + [parent]
        let ids = records.map(\.meetingID)
        for id in ids { try MeetingCanonicalID.validateMeetingID(id) }
        // Flush unrelated edits before the synchronous deletion transaction.
        // No suspension can add unrelated mutations between this and rollback.
        try save(context)
        let pending = records.filter { $0.status == .finalizingTranscript || $0.status == .stopping }
        let snapshots = pending.map { $0.persistenceSnapshot() }
        do {
            for record in pending { record.update(status: .transcriptFinalizationFailed) }
            if !pending.isEmpty { try save(context) }
        } catch {
            for (record, snapshot) in zip(pending, snapshots) { record.restore(snapshot) }
            throw error
        }
        // These records now durably own their provisional text and FLAC. Clearing
        // a marker first prevents a cleanup error from resurrecting a deleted row.
        for id in ids {
            try MeetingCaptureRecoveryStore.remove(meetingID: id, rootURL: rootURL)
        }
        do {
            for record in records { context.delete(record) }
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        var cleanupError: Error?
        for id in ids {
            let directory = rootURL.appendingPathComponent(id, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do { try FileManager.default.removeItem(at: directory) }
            catch { cleanupError = cleanupError ?? error }
        }
        if let cleanupError { throw cleanupError }
    }
}
