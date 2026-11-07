import Foundation
import SwiftData
import CryptoKit

/// Portable domain records only. No persistentIdentifier, local store URL, or save
/// crosses this boundary. The batch owner decides when its contexts are saved.
@MainActor
enum CloudModelCodec {
    enum CodecError: Error, Equatable {
        case unknownEntity(String)
        case invalidKey(String)
        case unsupportedSchema(String)
        case malformedPayload(String)
        case identityMismatch(String)
        case duplicateIdentity(String)
        case healthDataExcluded
    }

    /// Reconciliation must pass conflictingKeys as temporarilyUnavailable.
    /// Their absence from records never authorizes a tombstone or remote apply.
    struct Snapshot {
        var records = [String: Data]()
        var conflictingKeys = Set<String>()
        var versions = [String: [Data]]()
        var origins = [String: CloudSyncConflictVersion.Origin]()
        var digests = [String: String]()
        var meetingNamespaces = [String: Set<String>]()

        /// Local-only aggregate; CloudKit continues to receive individual v1 envelopes.
        var taskAggregateDigest: String {
            var hash = SHA256()
            for key in digests.keys.filter({ $0.hasPrefix("Todo/") }).sorted() {
                hash.update(data: Data((key + "\u{0}" + digests[key]! + "\n").utf8))
            }
            // Conflicted identities must not look like an empty/deleted task set.
            for key in conflictingKeys.filter({ $0.hasPrefix("Todo/") }).sorted() {
                hash.update(data: Data((key + "\u{0}conflict\n").utf8))
                for data in versions[key, default: []].sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    hash.update(data: Data(CloudFileStore.digest(data).utf8))
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// Replace complete entity inventories, never an arbitrary subset of rows.
        mutating func replace(entities: Set<String>, with inventory: Snapshot) {
            func retained(_ key: String) -> Bool {
                !entities.contains(String(key.prefix { $0 != "/" }))
            }
            records = records.filter { retained($0.key) }
            digests = digests.filter { retained($0.key) }
            versions = versions.filter { retained($0.key) }
            origins = origins.filter { retained($0.key) }
            meetingNamespaces = meetingNamespaces.filter { retained($0.key) }
            conflictingKeys = conflictingKeys.filter(retained)
            records.merge(inventory.records) { _, new in new }
            digests.merge(inventory.digests) { _, new in new }
            versions.merge(inventory.versions) { _, new in new }
            origins.merge(inventory.origins) { _, new in new }
            meetingNamespaces.merge(inventory.meetingNamespaces) { _, new in new }
            conflictingKeys.formUnion(inventory.conflictingKeys)
        }

        /// Strict export/migration consumers must reject a partial snapshot.
        func validatedRecords() throws -> [String: Data] {
            if let key = conflictingKeys.min() { throw CodecError.duplicateIdentity(key) }
            return records
        }
    }

    /// Cached bytes are reusable only after an authoritative inventory fetch and
    /// an observed identifier-level save stream. Unknown invalidation clears it.
    final class CaptureCache {
        fileprivate struct Item {
            let key: String
            let payload: Data
            let digest: String
        }
        fileprivate var items = [String: [PersistentIdentifier: Item]]()
        var requiresFullInventory: Bool { items.isEmpty }

        func invalidate(identifiers: Set<PersistentIdentifier>) {
            for id in identifiers { items[id.entityName]?.removeValue(forKey: id) }
            // Health exclusion is a cross-entity dependency.
            if identifiers.contains(where: { $0.entityName == "Todo" }) {
                items.removeValue(forKey: "TaskAuditEvent")
                items.removeValue(forKey: "TaskBehaviorEvent")
            }
        }

        func invalidateAll() { items.removeAll() }
    }

    private struct Envelope: Codable {
        let version: Int
        let entity: String
        let identity: String
        // Each property is independently typed by its explicit key path below.
        // Optional.none is JSON null. Only explicit additive legacy defaults may be omitted.
        let fields: [String: Data]
    }

    private struct Field<Model: PersistentModel> {
        let name: String
        let encode: (Model, JSONEncoder) throws -> Data?
        let decode: (Model, Data, JSONDecoder) throws -> Void
        let copy: (Model, Model) -> Void
        let decodeMissing: ((Model) -> Void)?
        let preservesLocalValueOnRestore: Bool

        init<Value: Codable>(_ name: String, _ path: ReferenceWritableKeyPath<Model, Value>, defaultValue: Value? = nil) {
            self.name = name
            encode = { model, encoder in try encoder.encode(model[keyPath: path]) }
            decode = { model, data, decoder in
                model[keyPath: path] = try decoder.decode(Value.self, from: data)
            }
            copy = { source, destination in destination[keyPath: path] = source[keyPath: path] }
            decodeMissing = defaultValue.map { value in { model in model[keyPath: path] = value } }
            preservesLocalValueOnRestore = false
        }

        /// Keep unchanged records byte-compatible with older strict decoders.
        init<Value: Codable & Equatable>(omittingDefault name: String,
                                       _ path: ReferenceWritableKeyPath<Model, Value>, defaultValue: Value) {
            self.name = name
            encode = { model, encoder in
                let value = model[keyPath: path]
                return value == defaultValue ? nil : try encoder.encode(value)
            }
            decode = { model, data, decoder in
                model[keyPath: path] = try decoder.decode(Value.self, from: data)
            }
            copy = { source, destination in destination[keyPath: path] = source[keyPath: path] }
            decodeMissing = { model in model[keyPath: path] = defaultValue }
            preservesLocalValueOnRestore = false
        }

        /// Register a schema property while transferring only a neutral value.
        /// Local store migration still copies the observed value losslessly.
        init<Value: Codable>(deviceLocal name: String, _ path: ReferenceWritableKeyPath<Model, Value>,
                             defaultValue: Value, preservesLocalValueOnRestore: Bool = false,
                             omitFromEnvelope: Bool = false) {
            self.name = name
            self.preservesLocalValueOnRestore = preservesLocalValueOnRestore
            encode = { _, encoder in omitFromEnvelope ? nil : try encoder.encode(defaultValue) }
            decode = { model, data, decoder in
                _ = try decoder.decode(Value.self, from: data)
                model[keyPath: path] = defaultValue
            }
            copy = { source, destination in destination[keyPath: path] = source[keyPath: path] }
            decodeMissing = { model in model[keyPath: path] = defaultValue }
        }
    }

    private struct Entity<Model: PersistentModel> {
        let name: String
        let make: () -> Model
        let identity: (Model) throws -> String
        let validIdentity: (String) -> Bool
        let fields: [Field<Model>]
        let fieldNames: Set<String>
        let requiredFieldNames: Set<String>
        let isSchemaSupported: Bool

        init(name: String, make: @escaping () -> Model, identity: @escaping (Model) throws -> String,
             validIdentity: @escaping (String) -> Bool, fields: [Field<Model>]) {
            self.name = name
            self.make = make
            self.identity = identity
            self.validIdentity = validIdentity
            self.fields = fields
            let names = Set(fields.map(\.name))
            self.fieldNames = names
            self.requiredFieldNames = Set(fields.filter { $0.decodeMissing == nil }.map(\.name))
            let schema = Schema([Model.self])
            if let entity = schema.entities.first(where: { $0.name == name }) {
                isSchemaSupported = entity.relationships.isEmpty
                    && Set(entity.properties.map(\.name)) == names
                    && entity.properties.count == fields.count
            } else {
                isSchemaSupported = false
            }
        }

        func validateSchema() throws {
            // SwiftData's public PropertyMetadata does not expose its key paths.
            // Explicit typed paths are checked against the public Schema instead;
            // a new/removed property or relationship fails closed, not silently lost.
            guard isSchemaSupported else {
                throw CodecError.unsupportedSchema(name)
            }
        }

        func key(_ model: Model) throws -> String { name + "/" + (try identity(model)) }

        func envelope(_ model: Model, encoder: JSONEncoder) throws -> Envelope {
            var values: [String: Data] = [:]
            values.reserveCapacity(fields.count)
            for field in fields where !field.preservesLocalValueOnRestore {
                values[field.name] = try field.encode(model, encoder)
            }
            return Envelope(version: 1, entity: name, identity: try identity(model), fields: values)
        }

        func decode(_ envelope: Envelope, decoder: JSONDecoder) throws -> Model {
            let keys = Set(envelope.fields.keys)
            guard envelope.version == 1, envelope.entity == name,
                  requiredFieldNames.isSubset(of: keys), keys.isSubset(of: fieldNames) else {
                throw CodecError.malformedPayload(name)
            }
            // Decode into an uninserted object. A bad final property cannot partly
            // overwrite an existing row or leave an inserted placeholder behind.
            let model = make()
            for field in fields {
                guard let data = envelope.fields[field.name] else {
                    guard let decodeMissing = field.decodeMissing else {
                        throw CodecError.malformedPayload(field.name)
                    }
                    decodeMissing(model)
                    continue
                }
                try field.decode(model, data, decoder)
            }
            guard try identity(model) == envelope.identity else {
                throw CodecError.identityMismatch(name)
            }
            return model
        }

        private func copyRestoredFields(from decoded: Model, to existing: Model) {
            // Compare before copying body fields. A remote metadata-only edit
            // cannot invalidate a complete provider fetch on this device.
            let localBodyVersion: Int?
            if let incoming = decoded as? EmailMessage, let local = existing as? EmailMessage,
               incoming.body == local.body, incoming.htmlBody == local.htmlBody {
                localBodyVersion = local.bodyContentVersion
            } else {
                localBodyVersion = nil
            }
            for field in fields where !field.preservesLocalValueOnRestore {
                field.copy(decoded, existing)
            }
            if let localBodyVersion, let local = existing as? EmailMessage {
                local.bodyContentVersion = localBodyVersion
            }
        }

        func erased() -> AnyEntity {
            AnyEntity(name: name, validIdentity: validIdentity, validateSchema: validateSchema,
                capture: { context, excludedTodoIDs, encoder, cache in
                    var result = Snapshot()
                    var inventory = [PersistentIdentifier: CaptureCache.Item]()
                    for model in try context.fetch(FetchDescriptor<Model>()) {
                        if let todo = model as? Todo, todo.isHealthRelated { continue }
                        if let audit = model as? TaskAuditEvent, excludedTodoIDs.contains(audit.todoID) { continue }
                        if let behavior = model as? TaskBehaviorEvent, excludedTodoIDs.contains(behavior.todoID) { continue }
                        let key = try key(model)
                        if let meeting = model as? MeetingRecord {
                            var ids = Set(meeting.audioTrackIDs)
                            ids.insert(meeting.meetingID)
                            if let parent = meeting.parentMeetingID { ids.insert(parent) }
                            result.meetingNamespaces[key, default: []].formUnion(ids)
                        }
                        let id = model.persistentModelID
                        let cached = cache?.items[name]?[id]
                        let data: Data
                        let digest: String
                        if let cached, cached.key == key {
                            data = cached.payload
                            digest = cached.digest
                        } else {
                            data = try encoder.encode(envelope(model, encoder: encoder))
                            digest = CloudFileStore.digest(data)
                        }
                        inventory[id] = CaptureCache.Item(key: key, payload: data, digest: digest)
                        if !result.versions[key, default: []].contains(data) {
                            result.versions[key, default: []].append(data)
                        }
                        if result.versions[key, default: []].count > 1 {
                            // Unavailable is not deleted. Retain every portable
                            // version for explicit review, including a third copy.
                            result.digests.removeValue(forKey: key)
                            result.records.removeValue(forKey: key)
                            result.conflictingKeys.insert(key)
                        } else {
                            result.records[key] = data
                            result.digests[key] = digest
                        }
                    }
                    cache?.items[name] = inventory
                    return result
                }, canonicalize: { envelope, encoder, decoder in
                    try encoder.encode(self.envelope(decode(envelope, decoder: decoder), encoder: encoder))
                }, apply: { identity, envelope, context, app, decoder, resolvingConflict in
                    let decoded = try envelope.map { try decode($0, decoder: decoder) }
                    if let todo = decoded as? Todo, todo.isHealthRelated {
                        throw CodecError.healthDataExcluded
                    }
                    let healthIDs = Set(try app.fetch(FetchDescriptor<Todo>()).filter(\.isHealthRelated).map(\.id))
                    if let audit = decoded as? TaskAuditEvent, healthIDs.contains(audit.todoID) {
                        throw CodecError.healthDataExcluded
                    }
                    if let behavior = decoded as? TaskBehaviorEvent, healthIDs.contains(behavior.todoID) {
                        throw CodecError.healthDataExcluded
                    }
                    let matches = try context.fetch(FetchDescriptor<Model>()).filter { try self.identity($0) == identity }
                    // A remote record must never overwrite or delete a local health row,
                    // even if an older client leaked the same UUID to the cloud.
                    for match in matches {
                        if let todo = match as? Todo, todo.isHealthRelated { throw CodecError.healthDataExcluded }
                        if let audit = match as? TaskAuditEvent, healthIDs.contains(audit.todoID) {
                            throw CodecError.healthDataExcluded
                        }
                        if let behavior = match as? TaskBehaviorEvent, healthIDs.contains(behavior.todoID) {
                            throw CodecError.healthDataExcluded
                        }
                    }
                    guard let decoded else {
                        for match in matches { context.delete(match) }
                        return
                    }
                    if !resolvingConflict, matches.count > 1, let first = matches.first {
                        let encoder = CloudModelCodec.encoder()
                        let previous = try encoder.encode(self.envelope(first, encoder: encoder))
                        // Validate the whole cohort before changing any row. A real
                        // conflict remains explicit, even if the incoming value matches
                        // one of its versions. No local version is silently discarded.
                        for match in matches.dropFirst() {
                            guard try encoder.encode(self.envelope(match, encoder: encoder)) == previous else {
                                throw CodecError.duplicateIdentity(name + "/" + identity)
                            }
                        }
                    }
                    if matches.isEmpty {
                        context.insert(decoded)
                    } else if resolvingConflict {
                        // Only explicit review can collapse differing physical
                        // duplicates. Prefer the row carrying the chosen portable
                        // value so its restore-preserved device metadata survives.
                        let encoder = CloudModelCodec.encoder()
                        let selected = try encoder.encode(self.envelope(decoded, encoder: encoder))
                        let keeper = try matches.first {
                            try encoder.encode(self.envelope($0, encoder: encoder)) == selected
                        } ?? matches[0]
                        copyRestoredFields(from: decoded, to: keeper)
                        for duplicate in matches where duplicate !== keeper { context.delete(duplicate) }
                    } else {
                        // Keep every physical row and its restore-preserved local fields.
                        // Updating just one would manufacture a conflict on the next capture.
                        for existing in matches {
                            copyRestoredFields(from: decoded, to: existing)
                        }
                    }
                })
        }
    }

    private struct AnyEntity {
        let name: String
        let validIdentity: (String) -> Bool
        let validateSchema: () throws -> Void
        let capture: (ModelContext, Set<UUID>, JSONEncoder, CaptureCache?) throws -> Snapshot
        let canonicalize: (Envelope, JSONEncoder, JSONDecoder) throws -> Data
        let apply: (String, Envelope?, ModelContext, ModelContext, JSONDecoder, Bool) throws -> Void
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }()

    private static func encoder() -> JSONEncoder { payloadEncoder }

    private static let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }()

    private static func decoder() -> JSONDecoder { payloadDecoder }

    private static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value).map { uuid($0) == value } ?? false
    }

    // Base64url of a JSON string tuple is collision-free, reversible, and safe in
    // a record key even for provider IDs containing slashes or punctuation.
    private static func stringIdentity(_ values: [String]) throws -> String {
        guard values.contains(where: { !$0.isEmpty }) else { throw CodecError.invalidKey("empty identity") }
        return try encoder().encode(values).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodedStringIdentity(_ value: String, count: Int) throws -> [String] {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw CodecError.invalidKey(value) }
        let values = try decoder().decode([String].self, from: data)
        guard values.count == count, try stringIdentity(values) == value else { throw CodecError.invalidKey(value) }
        return values
    }

    private static func validStringIdentity(_ value: String, count: Int) -> Bool {
        (try? decodedStringIdentity(value, count: count)) != nil
    }

    /// A tombstone must fence recovery even when its row has never existed on
    /// this installation. Decode the canonical key, not a possibly absent row.
    static func meetingID(for key: String) throws -> String? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "MeetingRecord" else { return nil }
        guard parts.count == 2 else { throw CodecError.invalidKey(key) }
        return try decodedStringIdentity(String(parts[1]), count: 1)[0]
    }

    struct MeetingNamespaceInfo {
        let ids: Set<String>
        let parent: String?
    }

    static func meetingNamespaceInfo(key: String, payload: Data?) throws -> MeetingNamespaceInfo? {
        guard let id = try meetingID(for: key) else { return nil }
        guard let payload else { return MeetingNamespaceInfo(ids: [id], parent: nil) }
        let envelope = try decoder().decode(Envelope.self, from: payload)
        guard envelope.entity + "/" + envelope.identity == key else { throw CodecError.identityMismatch(key) }
        guard envelope.version == 1, let tracks = envelope.fields["audioTrackIDs"],
              let parent = envelope.fields["parentMeetingID"] else { throw CodecError.malformedPayload(key) }
        var ids = Set(try decoder().decode([String].self, from: tracks))
        ids.insert(id)
        let parentID = try decoder().decode(String?.self, from: parent)
        if let parentID { ids.insert(parentID) }
        return MeetingNamespaceInfo(ids: ids, parent: parentID)
    }

    /// Link both parent references and root track manifests; older restored rows
    /// can contain only one side. All connected original namespaces are fenced.
    static func meetingNamespaceGraph(_ snapshot: Snapshot) throws -> [String: Set<String>] {
        var edges = [String: Set<String>]()
        for key in Set(snapshot.records.keys).union(snapshot.versions.keys) where key.hasPrefix("MeetingRecord/") {
            var ids = snapshot.meetingNamespaces[key, default: []]
            if ids.isEmpty {
                let versions = snapshot.versions[key] ?? snapshot.records[key].map { [$0] } ?? []
                for payload in versions {
                    ids.formUnion(try meetingNamespaceInfo(key: key, payload: payload)?.ids ?? [])
                }
            }
            for id in ids { edges[id, default: []].formUnion(ids) }
        }
        var result = [String: Set<String>]()
        var visited = Set<String>()
        for id in edges.keys where !visited.contains(id) {
            var component = Set<String>()
            var pending = [id]
            while let next = pending.popLast() {
                guard component.insert(next).inserted else { continue }
                pending.append(contentsOf: edges[next, default: []].subtracting(component))
            }
            visited.formUnion(component)
            for member in component { result[member] = component }
        }
        return result
    }

    private static let mainEntities = [todos.erased(), personas.erased(), audits.erased(),
        behaviors.erased(), analyses.erased(), ledgers.erased()]
    private static let emailEntities = [emails.erased()]
    private static let meetingEntities = [meetings.erased(), glossary.erased(), metadata.erased(),
        sources.erased(), observations.erased()]
    static let captureFamilies: [Set<String>] = [
        ["Todo", "TaskAuditEvent", "TaskBehaviorEvent"], ["Persona"], ["MemoryAnalysis"],
        ["MailAnalysisLedgerRecord"], ["EmailMessage"], ["MeetingRecord"],
        ["MeetingGlossaryTerm", "VocabularyStoreMetadata", "VocabularySourceState", "VocabularyObservation"]
    ]
    private static let captureFamiliesCoverSchema =
        captureFamilies.reduce(into: Set<String>(), { $0.formUnion($1) }) == entityNames
    struct CaptureResult {
        var snapshot: Snapshot
        var unavailableEntities = Set<String>()
        var firstError: (any Error)?
    }

    /// A failed family keeps its previous inventory unavailable, never absent.
    /// Callers must hold every key in unavailableEntities, including remote-only keys.
    static func captureAvailable(app: ModelContext, email: ModelContext, meeting: ModelContext,
        previous: Snapshot, entities: Set<String>, cache: CaptureCache
    ) -> CaptureResult {
        var result = CaptureResult(snapshot: previous)
        guard captureFamiliesCoverSchema else {
            result.unavailableEntities = entityNames
            result.firstError = CodecError.unsupportedSchema("capture families")
            return result
        }
        for family in captureFamilies where !family.isDisjoint(with: entities) {
            do {
                let inventory = try capture(app: app, email: email, meeting: meeting, entities: family, cache: cache)
                result.snapshot.replace(entities: family, with: inventory)
            } catch {
                result.unavailableEntities.formUnion(family)
                result.firstError = result.firstError ?? error
            }
        }
        return result
    }



    static let entityNames = Set((mainEntities + emailEntities + meetingEntities).map(\.name))

    static func entityName(for key: String) -> String? {
        let name = String(key.prefix { $0 != "/" })
        return entityNames.contains(name) ? name : nil
    }
    static func isModelKey(_ key: String) -> Bool {
        entityName(for: key) != nil
    }

    private static func validate(_ entities: [AnyEntity], in context: ModelContext) throws {
        // Additional transport/shadow entities are intentionally not serialized.
        // Every domain entity we own must still match its complete stored schema.
        let actual = Set(context.container.schema.entities.map(\.name))
        guard Set(entities.map(\.name)).isSubset(of: actual) else {
            throw CodecError.unsupportedSchema("missing domain entity")
        }
        for entity in entities { try entity.validateSchema() }
    }

    static func captureMain(_ app: ModelContext) throws -> Snapshot {
        try capture(groups: [(mainEntities, app)], app: app)
    }

    static func capture(app: ModelContext, email: ModelContext, meeting: ModelContext,
                        entities: Set<String>? = nil, cache: CaptureCache? = nil) throws -> Snapshot {
        try capture(groups: [(mainEntities, app), (emailEntities, email), (meetingEntities, meeting)],
            app: app, entities: entities, cache: cache)
    }

    private static func capture(groups: [([AnyEntity], ModelContext)], app: ModelContext,
                                entities selected: Set<String>? = nil, cache: CaptureCache? = nil) throws -> Snapshot {
        for (entities, context) in groups {
            try validate(entities.filter { selected?.contains($0.name) ?? true }, in: context)
        }
        let needsHealthIDs = groups.contains { entities, _ in
            entities.contains { (selected?.contains($0.name) ?? true)
                && ($0.name == "TaskAuditEvent" || $0.name == "TaskBehaviorEvent") }
        }
        let healthIDs = needsHealthIDs
            ? Set(try app.fetch(FetchDescriptor<Todo>()).filter(\.isHealthRelated).map(\.id)) : []
        let encoder = encoder()
        var result = Snapshot()
        for (entities, context) in groups {
            for entity in entities where selected?.contains(entity.name) ?? true {
                let snapshot = try entity.capture(context, healthIDs, encoder, cache)
                result.records.merge(snapshot.records) { _, value in value }
                result.conflictingKeys.formUnion(snapshot.conflictingKeys)
                result.versions.merge(snapshot.versions) { first, second in first + second }
                result.digests.merge(snapshot.digests) { _, value in value }
                result.meetingNamespaces.merge(snapshot.meetingNamespaces) { $0.union($1) }
            }
        }
        return result
    }

    static func apply(key: String, payload: Data?, app: ModelContext, email: ModelContext, meeting: ModelContext,
                      resolvingConflict: Bool = false) throws {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw CodecError.invalidKey(key) }
        let name = String(parts[0]), identity = String(parts[1])
        let groups = [(mainEntities, app), (emailEntities, email), (meetingEntities, meeting)]
        guard let (entities, context) = groups.first(where: { $0.0.contains(where: { $0.name == name }) }),
              let entity = entities.first(where: { $0.name == name }) else {
            throw CodecError.unknownEntity(name)
        }
        guard entity.validIdentity(identity) else { throw CodecError.invalidKey(key) }
        try entity.validateSchema()
        let decoder = decoder()
        let envelope = try payload.map { try decoder.decode(Envelope.self, from: $0) }
        if let envelope {
            guard envelope.entity == name, envelope.identity == identity else { throw CodecError.identityMismatch(key) }
        }
        try entity.apply(identity, envelope, context, app, decoder, resolvingConflict)
    }

    private static let emailAnalysisFieldNames: Set<String> = [
        "analysisStateRaw", "analysisSummary", "analysisDetail",
        "analysisKeyPoints", "analysisActionItems", "analysisError",
        "analysisFailureReasonRaw", "analyzedBodyFingerprint", "analyzedAt",
        "analysisVersion", "analysisTodoCandidate", "analysisTodoCandidateFingerprint"
    ]

    /// Re-decode through the registered typed schema: old absent default fields,
    /// dictionary ordering, and device-local neutral values are not user edits.
    /// Dates, ordering of arrays and every actual domain value remain significant.
    static func semanticDigest(key: String, payload: Data?) throws -> String? {
        guard let payload else { return nil }
        let envelope = try decoder().decode(Envelope.self, from: payload)
        guard key == envelope.entity + "/" + envelope.identity,
              let entity = (mainEntities + emailEntities + meetingEntities).first(where: { $0.name == envelope.entity }),
              entity.validIdentity(envelope.identity) else { throw CodecError.identityMismatch(key) }
        try entity.validateSchema()
        if envelope.entity == "EmailMessage" {
            let model = try emails.decode(envelope, decoder: decoder())
            if !model.analyzedBodyFingerprint.isEmpty {
                let canonical = try emails.envelope(model, encoder: encoder())
                let semanticFields = canonical.fields.filter { name, _ in
                    name == "analyzedBodyFingerprint" || !emailAnalysisFieldNames.contains(name)
                }
                let normalized = Envelope(version: canonical.version, entity: canonical.entity,
                    identity: canonical.identity, fields: semanticFields)
                return CloudFileStore.digest(try encoder().encode(normalized))
            }
        }
        return CloudFileStore.digest(try entity.canonicalize(envelope, encoder(), decoder()))
    }

    /// Deterministically converges concurrent per-device email analyses when every
    /// non-analysis field and the non-empty analyzed body fingerprint match.
    /// Returns nil whenever any user/mailbox field differs so user edits are never lost.
    static func preferredEmailAnalysisPayload(key: String, candidates: [Data]) -> Data? {
        guard key.hasPrefix("EmailMessage/"), !candidates.isEmpty else { return nil }
        do {
            try emails.validateSchema()
            let jsonDecoder = decoder()
            let jsonEncoder = encoder()
            struct Candidate {
                let raw: Data
                let canonicalBytes: Data
                let nonAnalysisFields: [String: Data]
                let fingerprint: String
                let isAnalyzed: Bool
                let hasNoFailure: Bool
                let version: Int
                let analyzedAt: Date?
            }
            var parsed = [Candidate]()
            parsed.reserveCapacity(candidates.count)
            for raw in candidates {
                let envelope = try jsonDecoder.decode(Envelope.self, from: raw)
                guard envelope.entity == "EmailMessage",
                      key == "EmailMessage/" + envelope.identity,
                      emails.validIdentity(envelope.identity) else { return nil }
                let model = try emails.decode(envelope, decoder: jsonDecoder)
                guard !model.analyzedBodyFingerprint.isEmpty else { return nil }
                let canonical = try emails.envelope(model, encoder: jsonEncoder)
                let canonicalBytes = try jsonEncoder.encode(canonical)
                let nonAnalysis = canonical.fields.filter { !emailAnalysisFieldNames.contains($0.key) }
                parsed.append(Candidate(
                    raw: raw,
                    canonicalBytes: canonicalBytes,
                    nonAnalysisFields: nonAnalysis,
                    fingerprint: model.analyzedBodyFingerprint,
                    isAnalyzed: model.analysisState == .analyzed,
                    hasNoFailure: model.analysisFailureReasonRaw == nil,
                    version: model.analysisVersion,
                    analyzedAt: model.analyzedAt
                ))
            }
            guard let first = parsed.first,
                  parsed.dropFirst().allSatisfy({
                      $0.fingerprint == first.fingerprint && $0.nonAnalysisFields == first.nonAnalysisFields
                  }) else { return nil }
            let winner = parsed.min { lhs, rhs in
                if lhs.isAnalyzed != rhs.isAnalyzed { return lhs.isAnalyzed }
                if lhs.hasNoFailure != rhs.hasNoFailure { return lhs.hasNoFailure }
                if lhs.version != rhs.version { return lhs.version > rhs.version }
                switch (lhs.analyzedAt, rhs.analyzedAt) {
                case let (l?, r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                return lhs.canonicalBytes.lexicographicallyPrecedes(rhs.canonicalBytes)
            }
            return winner?.raw
        } catch {
            return nil
        }
    }

    /// Every field remains present for comparison; no heuristic title/notes-only
    /// equality is allowed to erase a different domain value.
    static func reviewVersion(key: String, payload: Data?, origin: CloudSyncConflictVersion.Origin,
                              source: String, revision: String = "") throws -> CloudSyncConflictVersion {
        let digest = payload.map(CloudFileStore.digest) ?? "deleted"
        guard let payload else {
            return CloudSyncConflictVersion(id: "\(origin.rawValue):\(source):\(revision):\(digest)",
                origin: origin, source: source, modifiedAt: nil, fields: [], payload: nil)
        }
        let envelope = try decoder().decode(Envelope.self, from: payload)
        guard key == envelope.entity + "/" + envelope.identity else { throw CodecError.identityMismatch(key) }
        let fields = try envelope.fields.keys.sorted().map { name in
            let data = envelope.fields[name]!
            let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let readable: String
            if name.hasSuffix("Data"), let bytes = try? decoder().decode(Data.self, from: data) {
                if let json = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) {
                    readable = String(decoding: try JSONSerialization.data(withJSONObject: json,
                        options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]), as: UTF8.self)
                } else if let text = String(data: bytes, encoding: .utf8) { readable = text }
                else { readable = "\(bytes.count) bytes · SHA-256 \(CloudFileStore.digest(bytes))" }
            } else if let text = value as? String { readable = text }
            else {
                readable = String(decoding: try JSONSerialization.data(withJSONObject: value,
                    options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]), as: UTF8.self)
            }
            return CloudSyncConflictField(id: name, name: name, value: readable)
        }
        let date = ["updatedAt", "createdAt", "receivedAt", "occurredAt", "observedAt"].compactMap {
            envelope.fields[$0].flatMap { try? decoder().decode(Date.self, from: $0) }
        }.first
        return CloudSyncConflictVersion(id: "\(origin.rawValue):\(source):\(revision):\(digest)",
            origin: origin, source: source, modifiedAt: date, fields: fields, payload: payload)
    }

    // MARK: Lossless local-only main-store merge

    struct MainStoreSnapshot {
        fileprivate let todos: [Todo]
        fileprivate let personas: [Persona]
        fileprivate let audits: [TaskAuditEvent]
        fileprivate let behaviors: [TaskBehaviorEvent]
        fileprivate let analyses: [MemoryAnalysis]
        fileprivate let ledgers: [MailAnalysisLedgerRecord]
    }

    private static func snapshot<Model>(_ entity: Entity<Model>, from context: ModelContext) throws -> [Model] {
        try entity.validateSchema()
        return try context.fetch(FetchDescriptor<Model>()).map { source in
            let copy = entity.make()
            for field in entity.fields { field.copy(source, copy) }
            return copy
        }
    }

    static func snapshotMainStore(from source: ModelContext) throws -> MainStoreSnapshot {
        try validate(mainEntities, in: source)
        return try MainStoreSnapshot(todos: snapshot(todos, from: source), personas: snapshot(personas, from: source),
            audits: snapshot(audits, from: source), behaviors: snapshot(behaviors, from: source),
            analyses: snapshot(analyses, from: source), ledgers: snapshot(ledgers, from: source))
    }

    static func mergeMainStore(from source: ModelContext, into destination: ModelContext) throws {
        try mergeMainStore(snapshotMainStore(from: source), into: destination)
    }

    static func mergeMainStore(_ snapshot: MainStoreSnapshot, into destination: ModelContext) throws {
        try validate(mainEntities, in: destination)
        var actions: [() -> Void] = []
        var todoIDs: [UUID: UUID] = [:]
        try planMerge(snapshot.todos, entity: todos, id: \.id, into: destination, actions: &actions) {
            original, replacement in todoIDs[original] = replacement
        }
        try planMerge(snapshot.personas, entity: personas, id: \.id, into: destination, actions: &actions)
        // Remap source cohort joins only when its Todo collided. Destination
        // cohorts remain attached to their original Todo. Snapshot is reusable.
        let auditCopies = snapshot.audits.map { source in
            let copy = audits.make()
            for field in audits.fields { field.copy(source, copy) }
            copy.todoID = todoIDs[source.todoID] ?? source.todoID
            return copy
        }
        let behaviorCopies = snapshot.behaviors.map { source in
            let copy = behaviors.make()
            for field in behaviors.fields { field.copy(source, copy) }
            copy.todoID = todoIDs[source.todoID] ?? source.todoID
            return copy
        }
        try planMerge(auditCopies, entity: audits, id: \.id, into: destination, actions: &actions)
        try planMerge(behaviorCopies, entity: behaviors, id: \.id, into: destination, actions: &actions)
        try planMerge(snapshot.analyses, entity: analyses, id: \.id, into: destination, actions: &actions)
        try planMergeRows(snapshot.ledgers, entity: ledgers, into: destination, actions: &actions, conflict: { copy, data in
            copy.syncIdentity = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        })
        // All fetches, schema checks, encoding and conflict checks precede mutation.
        for action in actions { action() }
    }

    private static func planMerge<Model>(_ rows: [Model], entity: Entity<Model>,
        id: ReferenceWritableKeyPath<Model, UUID>, into destination: ModelContext,
        actions: inout [() -> Void], remapped: (UUID, UUID) -> Void = { _, _ in }) throws {
        try planMergeRows(rows, entity: entity, into: destination, actions: &actions, conflict: { copy, data in
            let digest = Array(SHA256.hash(data: data).prefix(16))
            copy[keyPath: id] = UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                digest[4], digest[5], digest[6], digest[7], digest[8], digest[9],
                digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        }, remapped: { original, copy in remapped(original[keyPath: id], copy[keyPath: id]) })
    }

    private static func planMergeRows<Model>(_ rows: [Model], entity: Entity<Model>, into destination: ModelContext,
        actions: inout [() -> Void], conflict: (Model, Data) -> Void,
        remapped: (Model, Model) -> Void = { _, _ in }) throws {
        let encoder = encoder()
        var existing: [String: Data] = [:]
        for row in try destination.fetch(FetchDescriptor<Model>()) {
            let rowID = try entity.identity(row)
            let data = try encoder.encode(entity.envelope(row, encoder: encoder))
            guard existing[rowID] == nil else { throw CodecError.duplicateIdentity(try entity.key(row)) }
            existing[rowID] = data
        }
        for row in rows {
            let originalID = try entity.identity(row)
            let originalData = try encoder.encode(entity.envelope(row, encoder: encoder))
            if existing[originalID] == originalData { continue }
            let copy = entity.make()
            for field in entity.fields { field.copy(row, copy) }
            if existing[originalID] != nil {
                // A deterministic conflict identity retains both complete versions
                // and makes a retried import idempotent without touching its source.
                conflict(copy, originalData)
                remapped(row, copy)
            }
            let copyID = try entity.identity(copy)
            let copyData = try encoder.encode(entity.envelope(copy, encoder: encoder))
            if let previous = existing[copyID] {
                guard previous == copyData else { throw CodecError.duplicateIdentity(try entity.key(copy)) }
                continue
            }
            existing[copyID] = copyData
            actions.append { destination.insert(copy) }
        }
    }

    // MARK: Complete typed property tables (schema additions fail closed)

    private static let todos = Entity<Todo>(name: "Todo", make: { Todo() }, identity: { uuid($0.id) },
        validIdentity: validUUID, fields: [
            .init("id", \.id), .init("title", \.title), .init("notes", \.notes),
            .init("createdAt", \.createdAt), .init("updatedAt", \.updatedAt),
            .init("dueDate", \.dueDate), .init("startDate", \.startDate),
            .init("isCompleted", \.isCompleted), .init("completedAt", \.completedAt),
            .init("manualPriority", \.manualPriority), .init("computedPriorityScore", \.computedPriorityScore),
            .init("priorityReason", \.priorityReason), .init("reminderOffsets", \.reminderOffsets),
            .init("estimatedDurationMinutes", \.estimatedDurationMinutes), .init("source", \.source),
            .init("sourceRef", \.sourceRef), .init("sourceSender", \.sourceSender),
            .init("sourceMessageID", \.sourceMessageID), .init("sourceThreadID", \.sourceThreadID),
            .init("sourceSenderEmail", \.sourceSenderEmail), .init("sourceAccountNamespace", \.sourceAccountNamespace),
            .init(omittingDefault: "sourceItemID", \.sourceItemID, defaultValue: ""),
            .init("triageStatus", \.triageStatus), .init("tags", \.tags),
            .init("calendarEventID", \.calendarEventID), .init("calendarEventExternalID", \.calendarEventExternalID),
            .init(deviceLocal: "calendarSourceID", \.calendarSourceID, defaultValue: ""),
            .init("calendarEventOrigin", \.calendarEventOrigin), .init("calendarSyncedTitle", \.calendarSyncedTitle),
            .init("memoryNotes", \.memoryNotes), .init("aiRecommendedTime", \.aiRecommendedTime),
            .init("aiNeedsNotification", \.aiNeedsNotification), .init("aiPersonaFit", \.aiPersonaFit),
            .init("aiDetail", \.aiDetail), .init("aiEngine", \.aiEngine),
            .init("aiRequestedProvider", \.aiRequestedProvider), .init("aiFallbackReason", \.aiFallbackReason),
            .init("isFixedSchedule", \.isFixedSchedule)
        ])
    private static let personas = Entity<Persona>(name: "Persona", make: { Persona() }, identity: { uuid($0.id) },
        validIdentity: validUUID, fields: [
            .init("id", \.id), .init("descriptionText", \.descriptionText),
            .init("personaTypeRaw", \.personaTypeRaw), .init("updatedAt", \.updatedAt)
        ])
    private static let audits = Entity<TaskAuditEvent>(name: "TaskAuditEvent", make: { TaskAuditEvent(from: Todo()) },
        identity: { uuid($0.id) }, validIdentity: validUUID, fields: [
            .init("id", \.id), .init("todoID", \.todoID), .init("createdAt", \.createdAt),
            .init("completedAt", \.completedAt), .init("deletedAt", \.deletedAt),
            .init("sourceType", \.sourceType), .init("triageType", \.triageType),
            .init("wasFixedSchedule", \.wasFixedSchedule), .init("hadDueDate", \.hadDueDate),
            .init("dueDate", \.dueDate), .init("tags", \.tags)
        ])
    private static let behaviors = Entity<TaskBehaviorEvent>(name: "TaskBehaviorEvent",
        make: { TaskBehaviorEvent(todo: Todo(), type: .created, actor: .system, occurredAt: .distantPast) },
        identity: { uuid($0.id) }, validIdentity: validUUID, fields: [
            .init("id", \.id), .init("todoID", \.todoID), .init("occurredAt", \.occurredAt),
            .init("eventTypeRaw", \.eventTypeRaw), .init("actorRaw", \.actorRaw),
            .init("sourceType", \.sourceType), .init("triageType", \.triageType),
            .init("wasFixedSchedule", \.wasFixedSchedule), .init("todoCreatedAt", \.todoCreatedAt),
            .init("beforeCompletion", \.beforeCompletion), .init("afterCompletion", \.afterCompletion),
            .init("beforeDueDate", \.beforeDueDate), .init("afterDueDate", \.afterDueDate),
            .init("beforeManualPriority", \.beforeManualPriority), .init("afterManualPriority", \.afterManualPriority),
            .init("beforeComputedPriority", \.beforeComputedPriority), .init("afterComputedPriority", \.afterComputedPriority)
        ])
    private static let analyses = Entity<MemoryAnalysis>(name: "MemoryAnalysis",
        make: { MemoryAnalysis(summary: "", insights: [], fastTags: [], overdueRate: 0) },
        identity: { uuid($0.id) }, validIdentity: validUUID, fields: [
            .init("id", \.id), .init("summary", \.summary), .init("insights", \.insights), .init("fastTags", \.fastTags),
            .init("overdueRate", \.overdueRate), .init("productiveHour", \.productiveHour),
            .init("recordTitle", \.recordTitle), .init("accessScopeSummary", \.accessScopeSummary),
            .init("processorDescription", \.processorDescription), .init("createdAt", \.createdAt),
            .init("analysisVersion", \.analysisVersion), .init("windowStart", \.windowStart), .init("windowEnd", \.windowEnd),
            .init("sampleCount", \.sampleCount), .init("effectiveSampleSize", \.effectiveSampleSize),
            .init("confidenceRaw", \.confidenceRaw), .init("behaviorProfileData", \.behaviorProfileData)
        ])
    private static let ledgers = Entity<MailAnalysisLedgerRecord>(name: "MailAnalysisLedgerRecord",
        make: { MailAnalysisLedgerRecord(fingerprintData: Data(), revision: 0, stateRawValue: "") },
        identity: { model in
            guard !model.fingerprintData.isEmpty else { throw CodecError.invalidKey("MailAnalysisLedgerRecord") }
            return try stringIdentity([model.fingerprintData.base64EncodedString(), model.syncIdentity])
        }, validIdentity: { validStringIdentity($0, count: 2) }, fields: [
            .init("syncIdentity", \.syncIdentity), .init("fingerprintData", \.fingerprintData), .init("revision", \.revision),
            .init("stateRawValue", \.stateRawValue), .init("leaseExpiresAt", \.leaseExpiresAt), .init("analyzedAt", \.analyzedAt)
        ])
    private static let emails = Entity<EmailMessage>(name: "EmailMessage", make: { EmailMessage(id: "") },
        identity: { model in
            guard !model.id.isEmpty else { throw CodecError.invalidKey("EmailMessage") }
            return try stringIdentity([model.providerRawValue, model.sourceAccountNamespace, model.id])
        }, validIdentity: { validStringIdentity($0, count: 3) }, fields: [
            .init("id", \.id), .init("threadID", \.threadID), .init("subject", \.subject), .init("from", \.from),
            .init("snippet", \.snippet), .init("body", \.body), .init("htmlBody", \.htmlBody),
            .init(deviceLocal: "bodyContentVersion", \.bodyContentVersion, defaultValue: 0, omitFromEnvelope: true),
            .init("receivedAt", \.receivedAt), .init("isRead", \.isRead), .init("providerRawValue", \.providerRawValue),
            .init(deviceLocal: "hasBeenViewedInApp", \.hasBeenViewedInApp, defaultValue: true,
                  preservesLocalValueOnRestore: true),
            .init(deviceLocal: "lastBodyFetchAttemptAt", \.lastBodyFetchAttemptAt, defaultValue: Date.distantPast,
                  preservesLocalValueOnRestore: true),
            .init("rawMessageID", \.rawMessageID), .init("providerGlobalMessageID", \.providerGlobalMessageID),
            .init("labelIDs", \.labelIDs), .init("isInInbox", \.isInInbox),
            .init("outlookInferenceClassificationRawValue", \.outlookInferenceClassificationRawValue),
            .init("providerCategoryNames", \.providerCategoryNames), .init("providerFolderID", \.providerFolderID),
            .init("sourceAccountNamespace", \.sourceAccountNamespace), .init("analysisStateRaw", \.analysisStateRaw),
            .init("analysisSummary", \.analysisSummary), .init("analysisDetail", \.analysisDetail),
            .init("analysisKeyPoints", \.analysisKeyPoints), .init("analysisActionItems", \.analysisActionItems),
            .init("analysisError", \.analysisError), .init("analysisFailureReasonRaw", \.analysisFailureReasonRaw),
            .init("analyzedBodyFingerprint", \.analyzedBodyFingerprint), .init("analyzedAt", \.analyzedAt),
            .init("analysisVersion", \.analysisVersion), .init("analysisTodoCandidate", \.analysisTodoCandidate),
            .init("analysisTodoCandidateFingerprint", \.analysisTodoCandidateFingerprint)
        ])
    private static let meetings = Entity<MeetingRecord>(name: "MeetingRecord", make: { MeetingRecord() },
        identity: { try stringIdentity([$0.meetingID]) }, validIdentity: { validStringIdentity($0, count: 1) }, fields: [
            .init("meetingID", \.meetingID), .init("parentMeetingID", \.parentMeetingID), .init("audioTrackIDs", \.audioTrackIDs),
            .init("audioTrackKindRaw", \.audioTrackKindRaw), .init("audioTrackSourceLabel", \.audioTrackSourceLabel),
            .init("audioTrackStartSample", \.audioTrackStartSample), .init("createdAt", \.createdAt), .init("updatedAt", \.updatedAt),
            .init("modeRaw", \.modeRaw), .init("languageTag", \.languageTag), .init("summaryLanguageTag", \.summaryLanguageTag),
            .init("automaticLanguageDetection", \.automaticLanguageDetection, defaultValue: false),
            .init("summaryFormatRaw", \.summaryFormatRaw, defaultValue: "minutes"),
            .init("summaryCustomInstructions", \.summaryCustomInstructions, defaultValue: ""),
            .init("summaryKindRaw", \.summaryKindRaw), .init("summaryEngineLabel", \.summaryEngineLabel),
            .init("summaryFallbackReasonRaw", \.summaryFallbackReasonRaw), .init("summaryResultLanguageTag", \.summaryResultLanguageTag),
            .init("timezoneIdentifier", \.timezoneIdentifier), .init("statusRaw", \.statusRaw),
            .init("transcriptRevision", \.transcriptRevision), .init("resultData", \.resultData),
            .init("rawResultData", \.rawResultData), .init("appleRawResultData", \.appleRawResultData),
            .init("asrSourceRaw", \.asrSourceRaw), .init("asrModelRevision", \.asrModelRevision),
            .init("asrDetectedLanguages", \.asrDetectedLanguages), .init("offlineASRFailureRaw", \.offlineASRFailureRaw),
            .init("diarizationData", \.diarizationData), .init("refinementEngineLabel", \.refinementEngineLabel),
            .init("refinementFallbackReasonRaw", \.refinementFallbackReasonRaw), .init("manifestData", \.manifestData),
            .init("retentionUntil", \.retentionUntil), .init("confirmedTodoIDs", \.confirmedTodoIDs),
            .init("disclosureVersionID", \.disclosureVersionID), .init("importedAudioFileName", \.importedAudioFileName)
        ])
    private static let glossary = Entity<MeetingGlossaryTerm>(name: "MeetingGlossaryTerm",
        make: { MeetingGlossaryTerm(canonical: "") }, identity: { uuid($0.id) }, validIdentity: validUUID, fields: [
            .init("id", \.id), .init("canonical", \.canonical), .init("variants", \.variants), .init("category", \.category),
            .init("frequency", \.frequency), .init("source", \.source), .init("reverted", \.reverted),
            .init("createdAt", \.createdAt), .init("updatedAt", \.updatedAt), .init("lastSeenAt", \.lastSeenAt),
            .init("canonicalKey", \.canonicalKey), .init("userSpeechAliases", \.userSpeechAliases),
            .init("userCanonicalizationAliases", \.userCanonicalizationAliases), .init("confirmedLegacy", \.confirmedLegacy),
            .init("userConfirmedAt", \.userConfirmedAt), .init("rejectedAt", \.rejectedAt),
            .init("redirectCanonicalKey", \.redirectCanonicalKey), .init("exactEvidenceGroupCount", \.exactEvidenceGroupCount),
            .init("highConfidenceExactEvidenceGroupCount", \.highConfidenceExactEvidenceGroupCount),
            .init("correctionEvidenceGroupCount", \.correctionEvidenceGroupCount), .init("automaticMaxConfidence", \.automaticMaxConfidence),
            .init("observedSourceKinds", \.observedSourceKinds), .init("isDisplayUserEdited", \.isDisplayUserEdited),
            .init("isCategoryUserEdited", \.isCategoryUserEdited)
        ])
    private static let metadata = Entity<VocabularyStoreMetadata>(name: "VocabularyStoreMetadata", make: { VocabularyStoreMetadata() },
        identity: { try stringIdentity([$0.storeKey]) }, validIdentity: { validStringIdentity($0, count: 1) }, fields: [
            .init("storeKey", \.storeKey), .init("schemaRepairVersion", \.schemaRepairVersion), .init("hmacVerifier", \.hmacVerifier),
            .init("lastCompletedBackfillAt", \.lastCompletedBackfillAt),
            .init("lastCompletedBackfillExtractorVersion", \.lastCompletedBackfillExtractorVersion)
        ])
    private static let sources = Entity<VocabularySourceState>(name: "VocabularySourceState", make: { VocabularySourceState() },
        identity: { try stringIdentity([$0.sourceKey]) }, validIdentity: { validStringIdentity($0, count: 1) }, fields: [
            .init("sourceKey", \.sourceKey), .init("evidenceGroupKey", \.evidenceGroupKey), .init("sourceKindRaw", \.sourceKindRaw),
            .init("contentFingerprint", \.contentFingerprint), .init("extractorVersion", \.extractorVersion), .init("generation", \.generation),
            .init("enrichmentVersion", \.enrichmentVersion), .init("enrichmentStatusRaw", \.enrichmentStatusRaw),
            .init("lastEnrichmentAttemptAt", \.lastEnrichmentAttemptAt), .init("enrichmentFailureCount", \.enrichmentFailureCount),
            .init("updatedAt", \.updatedAt)
        ])
    private static let observations = Entity<VocabularyObservation>(name: "VocabularyObservation", make: { VocabularyObservation() },
        identity: { uuid($0.id) }, validIdentity: validUUID, fields: [
            .init("id", \.id), .init("canonicalKey", \.canonicalKey), .init("canonicalDisplay", \.canonicalDisplay),
            .init("sourceKey", \.sourceKey), .init("sourceGeneration", \.sourceGeneration), .init("evidenceGroupKey", \.evidenceGroupKey),
            .init("surfaceKey", \.surfaceKey), .init("surfaceDisplay", \.surfaceDisplay), .init("roleRaw", \.roleRaw),
            .init("evidenceKindRaw", \.evidenceKindRaw), .init("categoryRaw", \.categoryRaw),
            .init("confidence", \.confidence), .init("observedAt", \.observedAt)
        ])
}
