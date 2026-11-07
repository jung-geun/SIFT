import CryptoKit
import Foundation

nonisolated struct CloudFileSnapshot: Sendable {
    let key: String
    let url: URL
    let digest: String
    let byteCount: Int
}

nonisolated struct CloudFileInventory: Sendable {
    var files = [String: CloudFileSnapshot]()
    var authoritativeMeetingIDs = Set<String>()
    var unavailableMeetingIDs = Set<String>()
    /// Omitted bytes are deletion evidence only with a settled model tombstone.
    var fencedMeetingIDs = Set<String>()
    var namespaceDependencies = [String: Set<String>]()
    var firstError: (any Error)?
}

nonisolated enum CloudFileError: Error {
    case invalidPath, changingFile, oversizedFile
}

nonisolated enum CloudFileApplyResult: Sendable, Equatable {
    case applied
    case awaitingModelRestore
}

/// Only app-owned original content enters iCloud. Model downloads, health history,
/// diagnostics, live databases and temporary exports never enter this namespace.
actor CloudFileStore {
    nonisolated static let prefix = "file/"
    private let root: URL
    private var cached = [String: (size: Int, modified: Date, digest: String)]()
    nonisolated static func meetingID(for key: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let path = String(key.dropFirst(prefix.count))
        guard isPortablePath(path) else { return nil }
        return String(path.split(separator: "/")[1])
    }


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
                 isAuthorized: @escaping @Sendable () -> Bool = { true }) throws -> [String: CloudFileSnapshot] {
        let inventory = try captureInventory(includeMeetings: includeMeetings, isAuthorized: isAuthorized)
        if let error = inventory.firstError { throw error }
        return inventory.files
    }

    /// Each namespace is an authoritative inventory or explicitly unavailable.
    /// Never expose a partly enumerated directory as proof of local deletion.
    func captureInventory(includeMeetings: Bool = true,
                          isAuthorized: @escaping @Sendable () -> Bool = { true },
                          isMeetingAuthorized: @escaping @Sendable (String) -> Bool = { _ in true }) throws -> CloudFileInventory {
        try Self.checkAuthorization(isAuthorized)
        let manager = FileManager.default
        var inventory = CloudFileInventory()
        let meetings = try safeLocation(for: "Meetings")
        guard includeMeetings, try Self.exists(meetings) else { return inventory }
        let directories = try manager.contentsOfDirectory(at: meetings,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            try Self.checkAuthorization(isAuthorized)
            let id = directory.lastPathComponent
            guard isMeetingAuthorized(id) else {
                inventory.unavailableMeetingIDs.insert(id)
                continue
            }
            do {
                let authorization = try namespaceAuthorization(id, isAuthorized: isAuthorized,
                    isMeetingAuthorized: isMeetingAuthorized)
                let namespaceAuthorized = authorization.check
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CloudFileError.invalidPath
                }
                guard try !isDeletedMeeting(id, parents: authorization.parents, isAuthorized: namespaceAuthorized) else {
                    inventory.authoritativeMeetingIDs.insert(id)
                    inventory.fencedMeetingIDs.insert(id)
                    continue
                }
                var paths = [String]()
                for name in ["active-capture.json", "capture-recovery.json"] {
                    try Self.checkAuthorization(namespaceAuthorized)
                    let path = "Meetings/\(id)/\(name)"
                    if try Self.exists(location(for: path)) { paths.append(path) }
                }
                let audio = try safeLocation(for: "Meetings/\(id)/audio")
                if try Self.exists(audio) {
                    let files = try manager.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
                    for file in files {
                        try Self.checkAuthorization(namespaceAuthorized)
                        let path = "Meetings/\(id)/audio/\(file.lastPathComponent)"
                        if Self.isPortablePath(path) { paths.append(path) }
                    }
                }
                var namespace = [String: CloudFileSnapshot]()
                for path in paths {
                    try Self.checkAuthorization(namespaceAuthorized)
                    let url = try location(for: path)
                    let before = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard before.isRegularFile == true, let size = before.fileSize,
                          let modified = before.contentModificationDate else { throw CloudFileError.invalidPath }
                    guard size < 50 * 1_024 * 1_024 else { throw CloudFileError.oversizedFile }
                    let digest: String
                    if let known = cached[path], known.size == size, known.modified == modified {
                        digest = known.digest
                    } else {
                        digest = try Self.digest(file: url, isAuthorized: namespaceAuthorized)
                        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        try Self.checkAuthorization(namespaceAuthorized)
                        guard after.fileSize == size, after.contentModificationDate == modified else {
                            throw CloudFileError.changingFile
                        }
                        cached[path] = (size, modified, digest)
                    }
                    let key = Self.prefix + path
                    namespace[key] = CloudFileSnapshot(key: key, url: url, digest: digest, byteCount: size)
                }
                try Self.checkAuthorization(namespaceAuthorized)
                inventory.namespaceDependencies[id] = authorization.parents.union([id])
                inventory.files.merge(namespace) { _, new in new }
                inventory.authoritativeMeetingIDs.insert(id)
            } catch {
                try Self.checkAuthorization(isAuthorized)
                inventory.unavailableMeetingIDs.insert(id)
                if !(error is CancellationError) { inventory.firstError = inventory.firstError ?? error }
            }
        }
        try Self.checkAuthorization(isAuthorized)
        return inventory
    }

    @discardableResult
    func apply(key: String, payload: Data?, expectedDigest: String?,
               isAuthorized: @escaping @Sendable () -> Bool = { true },
               isMeetingAuthorized: @escaping @Sendable (String) -> Bool = { _ in true }) throws -> CloudFileApplyResult {
        do {
            return try applyAuthorized(key: key, payload: payload, expectedDigest: expectedDigest,
                isAuthorized: isAuthorized, isMeetingAuthorized: isMeetingAuthorized)
        } catch is CancellationError {
            try Self.checkAuthorization(isAuthorized)
            // Only this namespace changed. Account revocation/task cancellation
            // still throws above; unrelated cloud keys may continue.
            throw CloudFileError.changingFile
        }
    }

    private func applyAuthorized(key: String, payload: Data?, expectedDigest: String?,
                                 isAuthorized accountAuthorized: @escaping @Sendable () -> Bool,
                                 isMeetingAuthorized: @escaping @Sendable (String) -> Bool) throws -> CloudFileApplyResult {
        try Self.checkAuthorization(accountAuthorized)
        guard key.hasPrefix(Self.prefix) else { throw CloudFileError.invalidPath }
        let path = String(key.dropFirst(Self.prefix.count))
        let url = try location(for: path)
        cached.removeValue(forKey: path)
        let id = String(path.split(separator: "/")[1])
        let parent = try payload.flatMap { data in
            path.hasSuffix(".json") ? try MeetingDeletionFence.markerParent(data, meetingID: id) : nil
        }
        let authorization = try namespaceAuthorization(id, incomingParent: parent,
            isAuthorized: accountAuthorized, isMeetingAuthorized: isMeetingAuthorized)
        let isAuthorized = authorization.check
        try Self.checkAuthorization(isAuthorized)
        if try discardIfDeleted(id, parent: parent, parents: authorization.parents,
            removeContent: payload == nil, isAuthorized: isAuthorized) {
            return payload == nil ? .applied : .awaitingModelRestore
        }
        let exists = try Self.exists(url)
        let current = exists ? try Self.digest(file: url, isAuthorized: isAuthorized) : nil
        try Self.checkAuthorization(isAuthorized)
        guard current == expectedDigest else { throw CloudFileError.changingFile }
        if try discardIfDeleted(id, parent: parent, parents: authorization.parents,
            removeContent: payload == nil, isAuthorized: isAuthorized) {
            return payload == nil ? .applied : .awaitingModelRestore
        }
        if let payload {
            guard payload.count < 50 * 1_024 * 1_024 else { throw CloudFileError.oversizedFile }
            let directory = url.deletingLastPathComponent()
            try Self.checkAuthorization(isAuthorized)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            // Re-resolve immediately before mutation; source and destination
            // metadata must never follow an intermediate symlink outside root.
            _ = try location(for: path)
            if try discardIfDeleted(id, parent: parent, parents: authorization.parents,
                removeContent: false, isAuthorized: isAuthorized) { return .awaitingModelRestore }
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
        return .applied
    }

    func load(_ snapshot: CloudFileSnapshot,
              isAuthorized: @escaping @Sendable () -> Bool = { true },
              isMeetingAuthorized: @escaping @Sendable (String) -> Bool = { _ in true }) throws -> Data {
        do {
            return try loadAuthorized(snapshot, isAuthorized: isAuthorized, isMeetingAuthorized: isMeetingAuthorized)
        } catch is CancellationError {
            try Self.checkAuthorization(isAuthorized)
            throw CloudFileError.changingFile
        }
    }

    private func loadAuthorized(_ snapshot: CloudFileSnapshot,
                                isAuthorized accountAuthorized: @escaping @Sendable () -> Bool,
                                isMeetingAuthorized: @escaping @Sendable (String) -> Bool) throws -> Data {
        try Self.checkAuthorization(accountAuthorized)
        guard snapshot.key.hasPrefix(Self.prefix) else { throw CloudFileError.invalidPath }
        let path = String(snapshot.key.dropFirst(Self.prefix.count))
        let url = try location(for: path)
        guard url.path == snapshot.url.standardizedFileURL.path else { throw CloudFileError.invalidPath }
        let id = String(path.split(separator: "/")[1])
        let authorization = try namespaceAuthorization(id, isAuthorized: accountAuthorized,
            isMeetingAuthorized: isMeetingAuthorized)
        let isAuthorized = authorization.check
        guard try !isDeletedMeeting(id, parents: authorization.parents, isAuthorized: isAuthorized) else { throw CancellationError() }
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

    private func discardIfDeleted(_ id: String, parent: String?, parents: Set<String>,
                                  removeContent: Bool, isAuthorized: @Sendable () -> Bool) throws -> Bool {
        let meetingRoot = try safeLocation(for: "Meetings")
        if try !MeetingDeletionFence.isDeleted(meetingID: id, rootURL: meetingRoot) {
            guard try MeetingDeletionFence.isDeleted(meetingID: id, parentMeetingID: parent, rootURL: meetingRoot)
                || isDeletedMeeting(id, parents: parents, isAuthorized: isAuthorized) else { return false }
            // Only inherit a parent's fence for a previously unknown child.
            // Never rewrite an existing own fence: an authoritative record
            // restore may concurrently clear it while this actor is reading.
            try Self.checkAuthorization(isAuthorized)
            try MeetingDeletionFence.recordDeletion(meetingID: id, rootURL: meetingRoot, isAuthorized: isAuthorized)
        }
        // A refused live asset is not an authoritative deletion operation.
        // Preserve original bytes and let the caller keep its apply intent pending.
        guard removeContent else { return true }
        try Self.checkAuthorization(isAuthorized)
        try MeetingDeletionFence.removeDeletedContent(meetingID: id, rootURL: meetingRoot, isAuthorized: isAuthorized)
        return true
    }

    private func isDeletedMeeting(_ id: String, parents: Set<String>,
                                  isAuthorized: @Sendable () -> Bool) throws -> Bool {
        try Self.checkAuthorization(isAuthorized)
        let meetingRoot = try safeLocation(for: "Meetings")
        if try MeetingDeletionFence.isDeleted(meetingID: id, rootURL: meetingRoot) { return true }
        for parent in parents {
            try Self.checkAuthorization(isAuthorized)
            if try MeetingDeletionFence.isDeleted(meetingID: id, parentMeetingID: parent, rootURL: meetingRoot) { return true }
        }
        return false
    }

    /// Marker-only children may be missing a model row on a joining device.
    /// Their stored or incoming parent must be fenced inside this file actor too.
    private func namespaceAuthorization(_ id: String, incomingParent: String? = nil,
        isAuthorized: @escaping @Sendable () -> Bool,
        isMeetingAuthorized: @escaping @Sendable (String) -> Bool
    ) throws -> (check: @Sendable () -> Bool, parents: Set<String>) {
        let ownAuthorized: @Sendable () -> Bool = { isAuthorized() && isMeetingAuthorized(id) }
        try Self.checkAuthorization(ownAuthorized)
        var parents = Set<String>()
        if let incomingParent { parents.insert(incomingParent) }
        for name in ["active-capture.json", "capture-recovery.json"] {
            let marker = try location(for: "Meetings/\(id)/\(name)")
            guard try Self.exists(marker) else { continue }
            try Self.checkAuthorization(ownAuthorized)
            let data = try Data(contentsOf: marker)
            try Self.checkAuthorization(ownAuthorized)
            if let parent = try MeetingDeletionFence.markerParent(data, meetingID: id) { parents.insert(parent) }
        }
        let parentIDs = parents
        let check: @Sendable () -> Bool = {
            ownAuthorized() && parentIDs.allSatisfy(isMeetingAuthorized)
        }
        try Self.checkAuthorization(check)
        return (check, parentIDs)
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
