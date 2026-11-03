import Foundation

nonisolated struct CloudSyncConflictField: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let value: String
}

nonisolated struct CloudSyncConflictVersion: Identifiable, Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case local, legacy, cloud, retained }
    let id: String
    let origin: Origin
    let source: String
    let modifiedAt: Date?
    let fields: [CloudSyncConflictField]
    let payload: Data?
}

nonisolated struct CloudSyncConflict: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let itemKey: String
    let entity: String
    let title: String
    let fingerprint: String
    let versions: [CloudSyncConflictVersion]

    init(key: String, versions: [CloudSyncConflictVersion], retained: Bool = false) {
        self.itemKey = key
        self.entity = String(key.prefix { $0 != "/" })
        self.versions = versions.sorted { $0.id < $1.id }
        self.fingerprint = CloudFileStore.digest(Data(self.versions.map(\.id).joined(separator: "\n").utf8))
        self.id = retained ? key + "#" + fingerprint : key
        self.title = Self.contentTitle(in: self.versions) ?? entity
    }

    /// Keep missing-title presentation separate from genuine source text that
    /// happens to equal an entity name; localization belongs to the view.
    var contentTitle: String? { Self.contentTitle(in: versions) }

    private static func contentTitle(in versions: [CloudSyncConflictVersion]) -> String? {
        versions.lazy.flatMap(\.fields).first {
            switch $0.name {
            case "title", "subject", "canonical", "recordTitle", "descriptionText":
                return !$0.value.isEmpty && $0.value != "null"
            default:
                return false
            }
        }?.value
    }
}

nonisolated enum CloudSyncConflictError: Error, Equatable {
    case staleSelection, versionUnavailable, busy, recordingActive, syncUnavailable, dependentContentUnavailable
}

/// Account-scoped protected recovery copies are independent of sync compaction.
/// Write the complete reviewed set before any canonical row or cloud mutation.
@MainActor
final class CloudSyncConflictArchive {
    let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> [CloudSyncConflict] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CloudSyncConflict].self, from: Data(contentsOf: url))
    }

    @discardableResult
    func retain(_ conflict: CloudSyncConflict) throws -> [CloudSyncConflict] {
        var saved = try load()
        let retained = CloudSyncConflict(key: conflict.itemKey, versions: conflict.versions, retained: true)
        if !saved.contains(where: { $0.id == retained.id }) { saved.insert(retained, at: 0) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(saved).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Recovery copies, unlike the fingerprint journal, are not excluded from
        // device backup. There is no automatic expiration or silent overwrite.
        return saved
    }
}
