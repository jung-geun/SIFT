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
        // Fence every owned identity before journals or rows disappear. Late
        // revisions for an unknown child also consult its parent's fence.
        let newlyFenced = try ids.filter { try !MeetingDeletionFence.isDeleted(meetingID: $0, rootURL: rootURL) }
        do {
            for id in ids { try MeetingDeletionFence.recordDeletion(meetingID: id, rootURL: rootURL) }
            for id in ids { try MeetingCaptureRecoveryStore.remove(meetingID: id, rootURL: rootURL) }
            for record in records { context.delete(record) }
            try save(context)
        } catch {
            context.rollback()
            // This local transaction never deleted its durably saved records.
            // Abort only fences created by this attempt; retain older deletions.
            for id in newlyFenced { try MeetingDeletionFence.recordAuthoritativeRestore(meetingID: id, rootURL: rootURL) }
            throw error
        }
        var cleanupError: Error?
        for id in ids {
            do { try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: rootURL) }
            catch { cleanupError = cleanupError ?? error }
        }
        if let cleanupError { throw cleanupError }
    }
}
