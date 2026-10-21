import CryptoKit
import Foundation

nonisolated struct CloudFileSnapshot: Sendable {
    let key: String
    let url: URL
    let digest: String
    let byteCount: Int
}

nonisolated enum CloudFileError: Error {
    case invalidPath, changingFile, oversizedFile
}

/// Only app-owned original content enters iCloud. Model downloads, health history,
/// diagnostics, live databases and temporary exports never enter this namespace.
actor CloudFileStore {
    nonisolated static let prefix = "file/"
    private let root: URL
    private var cached = [String: (size: Int, modified: Date, digest: String)]()

    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    nonisolated static func isPortablePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }),
              !path.contains("\0") else { return false }
        guard parts.count >= 3, parts[0] == "Meetings", UUID(uuidString: parts[1]) != nil else { return false }
        if parts.count == 3 {
            return parts[2] == "active-capture.json" || parts[2] == "capture-recovery.json"
        }
        guard parts.count == 4, parts[2] == "audio" else { return false }
        let name = parts[3]
        guard name.hasPrefix("part-"), name.hasSuffix(".flac") else { return false }
        let digits = name.dropFirst(5).dropLast(5)
        return digits.count == 2 && digits.allSatisfy(\.isNumber)
    }

    func capture(includeMeetings: Bool = true,
                 isAuthorized: @Sendable () -> Bool = { true }) throws -> [String: CloudFileSnapshot] {
        try Self.checkAuthorization(isAuthorized)
        let manager = FileManager.default
        var paths = [String]()
        let meetings = try safeLocation(for: "Meetings")
        if includeMeetings, try Self.exists(meetings) {
            let directories = try manager.contentsOfDirectory(at: meetings, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            try Self.checkAuthorization(isAuthorized)
            for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
                try Self.checkAuthorization(isAuthorized)
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let id = directory.lastPathComponent
                guard try !isDeletedMeeting(id, isAuthorized: isAuthorized) else { continue }
                for name in ["active-capture.json", "capture-recovery.json"] {
                    try Self.checkAuthorization(isAuthorized)
                    let path = "Meetings/\(id)/\(name)"
                    if try Self.exists(location(for: path)) { paths.append(path) }
                }
                let audio = try safeLocation(for: "Meetings/\(id)/audio")
                if try Self.exists(audio) {
                    let files = try manager.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
                    try Self.checkAuthorization(isAuthorized)
                    for file in files {
                        try Self.checkAuthorization(isAuthorized)
                        let path = "Meetings/\(id)/audio/\(file.lastPathComponent)"
                        if Self.isPortablePath(path) { paths.append(path) }
                    }
                }
            }
        }
        var result = [String: CloudFileSnapshot]()
        for path in paths {
            try Self.checkAuthorization(isAuthorized)
            let url = try location(for: path)
            let before = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard before.isRegularFile == true, let size = before.fileSize, let modified = before.contentModificationDate else {
                throw CloudFileError.invalidPath
            }
            // A 10-minute, 16 kHz mono FLAC part is below CloudKit's asset limit.
            guard size < 50 * 1_024 * 1_024 else { throw CloudFileError.oversizedFile }
            let digest: String
            if let known = cached[path], known.size == size, known.modified == modified {
                digest = known.digest
            } else {
                digest = try Self.digest(file: url, isAuthorized: isAuthorized)
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                try Self.checkAuthorization(isAuthorized)
                guard after.fileSize == size, after.contentModificationDate == modified else { throw CloudFileError.changingFile }
                cached[path] = (size, modified, digest)
            }
            let key = Self.prefix + path
            result[key] = CloudFileSnapshot(key: key, url: url, digest: digest, byteCount: size)
        }
        try Self.checkAuthorization(isAuthorized)
        return result
    }

    func apply(key: String, payload: Data?, expectedDigest: String?,
               isAuthorized: @Sendable () -> Bool = { true }) throws {
        try Self.checkAuthorization(isAuthorized)
        guard key.hasPrefix(Self.prefix) else { throw CloudFileError.invalidPath }
        let path = String(key.dropFirst(Self.prefix.count))
        let url = try location(for: path)
        cached.removeValue(forKey: path)
        let id = String(path.split(separator: "/")[1])
        let parent = try payload.flatMap { data in
            path.hasSuffix(".json") ? try MeetingDeletionFence.markerParent(data, meetingID: id) : nil
        }
        try Self.checkAuthorization(isAuthorized)
        if try discardIfDeleted(id, parent: parent, isAuthorized: isAuthorized) { return }
        let exists = try Self.exists(url)
        let current = exists ? try Self.digest(file: url, isAuthorized: isAuthorized) : nil
        try Self.checkAuthorization(isAuthorized)
        guard current == expectedDigest else { throw CloudFileError.changingFile }
        if try discardIfDeleted(id, parent: parent, isAuthorized: isAuthorized) { return }
        if let payload {
            guard payload.count < 50 * 1_024 * 1_024 else { throw CloudFileError.oversizedFile }
            let directory = url.deletingLastPathComponent()
            try Self.checkAuthorization(isAuthorized)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            // Re-resolve immediately before mutation; source and destination
            // metadata must never follow an intermediate symlink outside root.
            _ = try location(for: path)
            if try discardIfDeleted(id, parent: parent, isAuthorized: isAuthorized) { return }
            try Self.checkAuthorization(isAuthorized)
            try payload.write(to: url, options: [.atomic, .completeFileProtection])
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try Self.checkAuthorization(isAuthorized)
            try directoryURL.setResourceValues(values)
        } else if exists {
            _ = try location(for: path)
            try Self.checkAuthorization(isAuthorized)
            try FileManager.default.removeItem(at: url)
        }
        cached.removeValue(forKey: path)
    }

    func load(_ snapshot: CloudFileSnapshot,
              isAuthorized: @Sendable () -> Bool = { true }) throws -> Data {
        try Self.checkAuthorization(isAuthorized)
        guard snapshot.key.hasPrefix(Self.prefix) else { throw CloudFileError.invalidPath }
        let path = String(snapshot.key.dropFirst(Self.prefix.count))
        let url = try location(for: path)
        guard url.path == snapshot.url.standardizedFileURL.path else { throw CloudFileError.invalidPath }
        let id = String(path.split(separator: "/")[1])
        guard try !isDeletedMeeting(id, isAuthorized: isAuthorized) else { throw CancellationError() }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try Self.checkAuthorization(isAuthorized)
        let digest = try data.withUnsafeBytes { bytes -> String in
            var hash = SHA256()
            for start in stride(from: 0, to: bytes.count, by: 256 * 1_024) {
                try Self.checkAuthorization(isAuthorized)
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[start..<min(start + 256 * 1_024, bytes.count)]))
                try Self.checkAuthorization(isAuthorized)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        try Self.checkAuthorization(isAuthorized)
        guard digest == snapshot.digest else { throw CloudFileError.changingFile }
        return data
    }

    private func location(for path: String) throws -> URL {
        guard Self.isPortablePath(path) else { throw CloudFileError.invalidPath }
        return try safeLocation(for: path)
    }

    private func safeLocation(for path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
              url.resolvingSymlinksInPath().path == url.path else { throw CloudFileError.invalidPath }
        // URL resolution can leave an intermediate symlink unresolved when the
        // final audio directory or file does not exist yet. Check each existing
        // component before creating anything beneath it.
        var componentURL = root
        for component in path.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: componentURL.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw CloudFileError.invalidPath }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                break
            }
        }
        return url
    }

    private func discardIfDeleted(_ id: String, parent: String?, isAuthorized: @Sendable () -> Bool) throws -> Bool {
        let meetingRoot = try safeLocation(for: "Meetings")
        if try !MeetingDeletionFence.isDeleted(meetingID: id, rootURL: meetingRoot) {
            guard try MeetingDeletionFence.isDeleted(meetingID: id, parentMeetingID: parent, rootURL: meetingRoot)
                || isDeletedMeeting(id, isAuthorized: isAuthorized) else { return false }
            // Only inherit a parent's fence for a previously unknown child.
            // Never rewrite an existing own fence: an authoritative record
            // restore may concurrently clear it while this actor is reading.
            try Self.checkAuthorization(isAuthorized)
            try MeetingDeletionFence.recordDeletion(meetingID: id, rootURL: meetingRoot, isAuthorized: isAuthorized)
        }
        try Self.checkAuthorization(isAuthorized)
        try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: meetingRoot, isAuthorized: isAuthorized)
        return true
    }

    private func isDeletedMeeting(_ id: String, isAuthorized: @Sendable () -> Bool) throws -> Bool {
        try Self.checkAuthorization(isAuthorized)
        let meetingRoot = try safeLocation(for: "Meetings")
        if try MeetingDeletionFence.isDeleted(meetingID: id, rootURL: meetingRoot) { return true }
        for name in ["active-capture.json", "capture-recovery.json"] {
            try Self.checkAuthorization(isAuthorized)
            let marker = try location(for: "Meetings/\(id)/\(name)")
            guard try Self.exists(marker) else { continue }
            let data = try Data(contentsOf: marker)
            try Self.checkAuthorization(isAuthorized)
            let parent = try MeetingDeletionFence.markerParent(data, meetingID: id)
            if try MeetingDeletionFence.isDeleted(meetingID: id, parentMeetingID: parent, rootURL: meetingRoot) { return true }
        }
        return false
    }

    private nonisolated static func checkAuthorization(_ isAuthorized: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
    }

    private nonisolated static func exists(_ url: URL) throws -> Bool {
        do { return try url.checkResourceIsReachable() }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
    }

    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private nonisolated static func digest(file: URL, isAuthorized: @Sendable () -> Bool) throws -> String {
        try checkAuthorization(isAuthorized)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try checkAuthorization(isAuthorized)
            let bytes = try handle.read(upToCount: 256 * 1_024)
            try checkAuthorization(isAuthorized)
            guard let bytes, !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        try checkAuthorization(isAuthorized)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
