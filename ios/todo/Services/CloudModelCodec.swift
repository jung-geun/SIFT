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

    private struct Envelope: Codable {
        let version: Int
        let entity: String
        let identity: String
        // Each property is independently typed by its explicit key path below.
        // Optional.none is encoded as JSON null, never omitted or default-filled.
        let fields: [String: Data]
    }

    private struct Field<Model: PersistentModel> {
        let name: String
        let encode: (Model, JSONEncoder) throws -> Data
        let decode: (Model, Data, JSONDecoder) throws -> Void
        let copy: (Model, Model) -> Void
        let decodeMissing: ((Model) -> Void)?

        init<Value: Codable>(_ name: String, _ path: ReferenceWritableKeyPath<Model, Value>, defaultValue: Value? = nil) {
            self.name = name
            encode = { model, encoder in try encoder.encode(model[keyPath: path]) }
            decode = { model, data, decoder in
                model[keyPath: path] = try decoder.decode(Value.self, from: data)
            }
            copy = { source, destination in destination[keyPath: path] = source[keyPath: path] }
            decodeMissing = defaultValue.map { value in { model in model[keyPath: path] = value } }
        }

        /// Register the schema property without transferring device identifiers.
        /// Local store migration still copies the observed value losslessly.
        init(deviceLocal name: String, _ path: ReferenceWritableKeyPath<Model, String>) {
            self.name = name
            encode = { _, encoder in try encoder.encode("") }
            decode = { model, data, decoder in
                _ = try decoder.decode(String.self, from: data)
                model[keyPath: path] = ""
            }
            copy = { source, destination in destination[keyPath: path] = source[keyPath: path] }
            decodeMissing = { model in model[keyPath: path] = "" }
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
            for field in fields { values[field.name] = try field.encode(model, encoder) }
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

        func erased() -> AnyEntity {
            AnyEntity(name: name, validIdentity: validIdentity, validateSchema: validateSchema,
                capture: { context, excludedTodoIDs, encoder in
                    var result: [String: Data] = [:]
                    for model in try context.fetch(FetchDescriptor<Model>()) {
                        if let todo = model as? Todo, todo.isHealthRelated { continue }
                        if let audit = model as? TaskAuditEvent, excludedTodoIDs.contains(audit.todoID) { continue }
                        if let behavior = model as? TaskBehaviorEvent, excludedTodoIDs.contains(behavior.todoID) { continue }
                        let key = try key(model)
                        guard result[key] == nil else { throw CodecError.duplicateIdentity(key) }
                        result[key] = try encoder.encode(envelope(model, encoder: encoder))
                    }
                    return result
                }, apply: { identity, envelope, context, app, decoder in
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
                    guard matches.count <= 1 else { throw CodecError.duplicateIdentity(name + "/" + identity) }
                    if let existing = matches.first {
                        for field in fields { field.copy(decoded, existing) }
                    } else {
                        context.insert(decoded)
                    }
                })
        }
    }

    private struct AnyEntity {
        let name: String
        let validIdentity: (String) -> Bool
        let validateSchema: () throws -> Void
        let capture: (ModelContext, Set<UUID>, JSONEncoder) throws -> [String: Data]
        let apply: (String, Envelope?, ModelContext, ModelContext, JSONDecoder) throws -> Void
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

    private static let mainEntities = [todos.erased(), personas.erased(), audits.erased(),
        behaviors.erased(), analyses.erased(), ledgers.erased()]
    private static let emailEntities = [emails.erased()]
    private static let meetingEntities = [meetings.erased(), glossary.erased(), metadata.erased(),
        sources.erased(), observations.erased()]

    private static func validate(_ entities: [AnyEntity], in context: ModelContext) throws {
        // Additional transport/shadow entities are intentionally not serialized.
        // Every domain entity we own must still match its complete stored schema.
        let actual = Set(context.container.schema.entities.map(\.name))
        guard Set(entities.map(\.name)).isSubset(of: actual) else {
            throw CodecError.unsupportedSchema("missing domain entity")
        }
        for entity in entities { try entity.validateSchema() }
    }

    static func captureMain(_ app: ModelContext) throws -> [String: Data] {
        try capture(groups: [(mainEntities, app)], app: app)
    }

    static func capture(app: ModelContext, email: ModelContext, meeting: ModelContext) throws -> [String: Data] {
        try capture(groups: [(mainEntities, app), (emailEntities, email), (meetingEntities, meeting)], app: app)
    }

    private static func capture(groups: [([AnyEntity], ModelContext)], app: ModelContext) throws -> [String: Data] {
        for (entities, context) in groups { try validate(entities, in: context) }
        let healthIDs = Set(try app.fetch(FetchDescriptor<Todo>()).filter(\.isHealthRelated).map(\.id))
        let encoder = encoder()
        var payloads: [String: Data] = [:]
        for (entities, context) in groups {
            for entity in entities {
                for (key, data) in try entity.capture(context, healthIDs, encoder) { payloads[key] = data }
            }
        }
        return payloads
    }

    static func apply(key: String, payload: Data?, app: ModelContext, email: ModelContext, meeting: ModelContext) throws {
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
        try entity.apply(identity, envelope, context, app, decoder)
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
            .init("triageStatus", \.triageStatus), .init("tags", \.tags),
            .init("calendarEventID", \.calendarEventID), .init("calendarEventExternalID", \.calendarEventExternalID),
            .init(deviceLocal: "calendarSourceID", \.calendarSourceID),
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
            .init("receivedAt", \.receivedAt), .init("isRead", \.isRead), .init("providerRawValue", \.providerRawValue),
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
