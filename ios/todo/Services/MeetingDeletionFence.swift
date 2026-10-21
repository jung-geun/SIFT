import Darwin
import Foundation

/// Device-local deletion history, deliberately outside the portable file namespace.
/// A marker/audio revision is not authority to restore a deleted meeting identity.
nonisolated enum MeetingDeletionFence {
    private static let directoryName = ".deletion-fences"

    static func isDeleted(
        meetingID: String, parentMeetingID: String? = nil,
        rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws -> Bool {
        if try exists(fenceURL(meetingID: meetingID, rootURL: rootURL)) { return true }
        if let parentMeetingID {
            return try exists(fenceURL(meetingID: parentMeetingID, rootURL: rootURL))
        }
        return false
    }

    /// Persist BEFORE deleting the model, including when no local model exists.
    /// Replaying a cloud tombstone after a crash is idempotent. Never undo this
    /// fence on marker arrival, cleanup failure, foreground recovery or opt-in.
    static func recordDeletion(
        meetingID: String, rootURL: URL = AppDataContainer.meetingDirectory(),
        isAuthorized: @Sendable () -> Bool = { true }
    ) throws {
        try checkAuthorization(isAuthorized)
        let fence = try fenceURL(meetingID: meetingID, rootURL: rootURL)
        let directory = fence.deletingLastPathComponent()
        try checkAuthorization(isAuthorized)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        _ = try fenceURL(meetingID: meetingID, rootURL: rootURL)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try checkAuthorization(isAuthorized)
        try Data(meetingID.utf8).write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        let handle = try FileHandle(forUpdating: temporary)
        try handle.synchronize()
        try handle.close()
        try checkAuthorization(isAuthorized)
        guard Darwin.rename(temporary.path, fence.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronize(directory)
        // The fence directory itself must survive a crash on its first creation.
        try synchronize(directory.deletingLastPathComponent())
    }

    /// Call only after a genuinely newer, authoritative live MeetingRecord was
    /// applied and durably saved. Restoring a child never clears its parent fence.
    static func recordAuthoritativeRestore(
        meetingID: String, rootURL: URL = AppDataContainer.meetingDirectory()
    ) throws {
        let fence = try fenceURL(meetingID: meetingID, rootURL: rootURL)
        guard try exists(fence) else { return }
        try FileManager.default.removeItem(at: fence)
        try synchronize(fence.deletingLastPathComponent())
    }

    /// Call after model deletion; a failure leaves the durable fence intact.
    static func removeDeletedContent(
        meetingID: String, rootURL: URL = AppDataContainer.meetingDirectory(),
        isAuthorized: @Sendable () -> Bool = { true }
    ) throws {
        try checkAuthorization(isAuthorized)
        guard try isDeleted(meetingID: meetingID, rootURL: rootURL) else { return }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(meetingID, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw CloudFileError.invalidPath }
        if try exists(directory) {
            try checkAuthorization(isAuthorized)
            try FileManager.default.removeItem(at: directory)
            try synchronize(root)
        }
    }

    /// Read only identity metadata here: full recovery/audio validation belongs to
    /// the recovery store. This also works for an active capture's marker.
    static func markerParent(_ data: Data, meetingID: String) throws -> String? {
        struct Identity: Decodable {
            let meetingID: String
            let parentMeetingID: String?
        }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard identity.meetingID == meetingID else { throw CloudFileError.invalidPath }
        if let parent = identity.parentMeetingID { try validateID(parent) }
        return identity.parentMeetingID
    }

    private static func fenceURL(meetingID: String, rootURL: URL) throws -> URL {
        try validateID(meetingID)
        guard rootURL.isFileURL else { throw CloudFileError.invalidPath }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(meetingID)
        guard url.resolvingSymlinksInPath().path == url.path else { throw CloudFileError.invalidPath }
        return url
    }

    private static func validateID(_ id: String) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw CloudFileError.invalidPath
        }
    }

    private static func exists(_ url: URL) throws -> Bool {
        do { return try url.checkResourceIsReachable() }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
    }

    private static func checkAuthorization(_ isAuthorized: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
    }

    private static func synchronize(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
