import SwiftData
import Foundation

private struct FirebaseSnapshotEnvelope: Codable {
    let exportedAt: Date
    let personas: [FirebaseSnapshotPersona]
    let todos: [FirebaseSnapshotTodo]
    let audits: [FirebaseSnapshotAudit]
    let behaviorEvents: [FirebaseSnapshotBehaviorEvent]?
    let analyses: [FirebaseSnapshotAnalysis]
}

private struct FirebaseSnapshotPersona: Codable {
    let id: UUID
    let descriptionText: String
    let personaTypeRaw: String
    let updatedAt: Date
}

private struct FirebaseSnapshotTodo: Codable {
    let id: UUID
    let title: String
    let notes: String
    let createdAt: Date
    let updatedAt: Date
    /// Optional for backward-compatible imports of snapshots written before to-do start times existed.
    let startDate: Date?
    let dueDate: Date?
    let isCompleted: Bool
    let completedAt: Date?
    let manualPriority: Int?
    let computedPriorityScore: Double
    let priorityReason: String
    let reminderOffsets: [Double]
    let estimatedDurationMinutes: Int
    let source: String
    let sourceRef: String
    let sourceSender: String
    let sourceMessageID: String
    let sourceThreadID: String
    let sourceSenderEmail: String
    let sourceAccountNamespace: String?
    let triageStatus: String
    let tags: [String]
    let calendarEventID: String?
    let calendarEventExternalID: String
    /// Optional for backward-compatible imports of snapshots written before event provenance existed.
    let calendarEventOrigin: String?
    /// Optional for snapshots written before the calendar title baseline existed.
    let calendarSyncedTitle: String?
    let memoryNotes: String
    let aiRecommendedTime: Date?
    let aiNeedsNotification: Bool
    let aiPersonaFit: Bool
    let aiDetail: String
    let aiEngine: String
    let aiRequestedProvider: String
    let aiFallbackReason: String
    let isFixedSchedule: Bool
}

private struct FirebaseSnapshotAudit: Codable {
    let id: UUID
    let todoID: UUID?
    let createdAt: Date
    let completedAt: Date?
    let deletedAt: Date
    let sourceType: String
    let triageType: String
    let wasFixedSchedule: Bool
    let hadDueDate: Bool
    let dueDate: Date?
    let tags: [String]?
}

private struct FirebaseSnapshotBehaviorEvent: Codable {
    let todoCreatedAt: Date?
    let id: UUID
    let todoID: UUID
    let occurredAt: Date
    let eventTypeRaw: String
    let actorRaw: String
    let sourceType: String
    let triageType: String
    let wasFixedSchedule: Bool
    let beforeCompletion: Bool?
    let afterCompletion: Bool?
    let beforeDueDate: Date?
    let afterDueDate: Date?
    let beforeManualPriority: Int?
    let afterManualPriority: Int?
    let beforeComputedPriority: Double?
    let afterComputedPriority: Double?
}

private struct FirebaseSnapshotAnalysis: Codable {
    let id: UUID
    let summary: String
    let insights: [String]
    let fastTags: [String]
    let overdueRate: Double
    let productiveHour: Int?
    let createdAt: Date
    let recordTitle: String?
    let accessScopeSummary: String?
    let processorDescription: String?
    let analysisVersion: Int?
    let windowStart: Date?
    let windowEnd: Date?
    let sampleCount: Int?
    let effectiveSampleSize: Double?
    let confidenceRaw: String?
    let behaviorProfileData: Data?
}

enum FirebaseSnapshotStore {
    @MainActor
    static func exportJSON(context: ModelContext) throws -> String {
        let personas = (try? context.fetch(FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let audits = (try? context.fetch(FetchDescriptor<TaskAuditEvent>())) ?? []
        let behaviorEvents = (try? context.fetch(FetchDescriptor<TaskBehaviorEvent>())) ?? []
        let analyses = (try? context.fetch(FetchDescriptor<MemoryAnalysis>())) ?? []

        let envelope = FirebaseSnapshotEnvelope(
            exportedAt: Date(),
            personas: personas.map {
                FirebaseSnapshotPersona(
                    id: $0.id,
                    descriptionText: $0.descriptionText,
                    personaTypeRaw: $0.personaTypeRaw,
                    updatedAt: $0.updatedAt
                )
            },
            todos: todos.map {
                FirebaseSnapshotTodo(
                    id: $0.id,
                    title: $0.title,
                    notes: $0.notes,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    startDate: $0.startDate,
                    dueDate: $0.dueDate,
                    isCompleted: $0.isCompleted,
                    completedAt: $0.completedAt,
                    manualPriority: $0.manualPriority,
                    computedPriorityScore: $0.computedPriorityScore,
                    priorityReason: $0.priorityReason,
                    reminderOffsets: $0.reminderOffsets,
                    estimatedDurationMinutes: $0.estimatedDurationMinutes,
                    source: $0.source,
                    sourceRef: $0.sourceRef,
                    sourceSender: $0.sourceSender,
                    sourceMessageID: $0.sourceMessageID,
                    sourceThreadID: $0.sourceThreadID,
                    sourceSenderEmail: $0.sourceSenderEmail,
                    sourceAccountNamespace: $0.sourceAccountNamespace,
                    triageStatus: $0.triageStatus,
                    tags: $0.tags,
                    calendarEventID: $0.calendarEventID,
                    calendarEventExternalID: $0.calendarEventExternalID,
                    calendarEventOrigin: $0.calendarEventOrigin,
                    calendarSyncedTitle: $0.calendarSyncedTitle,
                    memoryNotes: $0.memoryNotes,
                    aiRecommendedTime: $0.aiRecommendedTime,
                    aiNeedsNotification: $0.aiNeedsNotification,
                    aiPersonaFit: $0.aiPersonaFit,
                    aiDetail: $0.aiDetail,
                    aiEngine: $0.aiEngine,
                    aiRequestedProvider: $0.aiRequestedProvider,
                    aiFallbackReason: $0.aiFallbackReason,
                    isFixedSchedule: $0.isFixedSchedule
                )
            },
            audits: audits.map {
                FirebaseSnapshotAudit(
                    id: $0.id,
                    todoID: $0.todoID,
                    createdAt: $0.createdAt,
                    completedAt: $0.completedAt,
                    deletedAt: $0.deletedAt,
                    sourceType: $0.sourceType,
                    triageType: $0.triageType,
                    wasFixedSchedule: $0.wasFixedSchedule,
                    hadDueDate: $0.hadDueDate,
                    dueDate: $0.dueDate,
                    tags: $0.tags
                )
            },
            behaviorEvents: behaviorEvents.map {
                FirebaseSnapshotBehaviorEvent(
                    todoCreatedAt: $0.todoCreatedAt,
                    id: $0.id,
                    todoID: $0.todoID,
                    occurredAt: $0.occurredAt,
                    eventTypeRaw: $0.eventTypeRaw,
                    actorRaw: $0.actorRaw,
                    sourceType: $0.sourceType,
                    triageType: $0.triageType,
                    wasFixedSchedule: $0.wasFixedSchedule,
                    beforeCompletion: $0.beforeCompletion,
                    afterCompletion: $0.afterCompletion,
                    beforeDueDate: $0.beforeDueDate,
                    afterDueDate: $0.afterDueDate,
                    beforeManualPriority: $0.beforeManualPriority,
                    afterManualPriority: $0.afterManualPriority,
                    beforeComputedPriority: $0.beforeComputedPriority,
                    afterComputedPriority: $0.afterComputedPriority
                )
            },
            analyses: analyses.map {
                FirebaseSnapshotAnalysis(
                    id: $0.id,
                    summary: $0.summary,
                    insights: $0.insights,
                    fastTags: $0.fastTags,
                    overdueRate: $0.overdueRate,
                    productiveHour: $0.productiveHour,
                    createdAt: $0.createdAt,
                    recordTitle: $0.recordTitle,
                    accessScopeSummary: $0.accessScopeSummary,
                    processorDescription: $0.processorDescription,
                    analysisVersion: $0.analysisVersion,
                    windowStart: $0.windowStart,
                    windowEnd: $0.windowEnd,
                    sampleCount: $0.sampleCount,
                    effectiveSampleSize: $0.effectiveSampleSize,
                    confidenceRaw: $0.confidenceRaw,
                    behaviorProfileData: $0.behaviorProfileData
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(envelope), encoding: .utf8) ?? "{}"
    }

    @MainActor
    static func importJSON(_ json: String, context: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(FirebaseSnapshotEnvelope.self, from: Data(json.utf8))

        for todo in (try? context.fetch(FetchDescriptor<Todo>())) ?? [] {
            context.delete(todo)
        }
        for persona in (try? context.fetch(FetchDescriptor<Persona>())) ?? [] {
            context.delete(persona)
        }
        for audit in (try? context.fetch(FetchDescriptor<TaskAuditEvent>())) ?? [] {
            context.delete(audit)
        }
        for event in (try? context.fetch(FetchDescriptor<TaskBehaviorEvent>())) ?? [] {
            context.delete(event)
        }
        for analysis in (try? context.fetch(FetchDescriptor<MemoryAnalysis>())) ?? [] {
            context.delete(analysis)
        }

        for payload in envelope.personas {
            let persona = Persona(descriptionText: payload.descriptionText, personaTypes: [])
            persona.id = payload.id
            persona.personaTypeRaw = payload.personaTypeRaw
            persona.updatedAt = payload.updatedAt
            context.insert(persona)
        }

        for payload in envelope.todos {
            let todo = Todo()
            todo.id = payload.id
            todo.title = payload.title
            todo.notes = payload.notes
            todo.createdAt = payload.createdAt
            todo.updatedAt = payload.updatedAt
            todo.startDate = payload.startDate
            todo.dueDate = payload.dueDate
            todo.isCompleted = payload.isCompleted
            todo.completedAt = payload.completedAt
            todo.manualPriority = payload.manualPriority
            todo.computedPriorityScore = payload.computedPriorityScore
            todo.priorityReason = payload.priorityReason
            todo.reminderOffsets = payload.reminderOffsets
            todo.estimatedDurationMinutes = payload.estimatedDurationMinutes
            todo.source = payload.source
            todo.sourceRef = payload.sourceRef
            todo.sourceSender = payload.sourceSender
            todo.sourceMessageID = payload.sourceMessageID
            todo.sourceThreadID = payload.sourceThreadID
            todo.sourceSenderEmail = payload.sourceSenderEmail
            todo.sourceAccountNamespace = payload.sourceAccountNamespace ?? ""
            todo.triageStatus = payload.triageStatus
            todo.tags = payload.tags
            todo.calendarEventID = payload.calendarEventID
            todo.calendarEventExternalID = payload.calendarEventExternalID
            todo.calendarEventOrigin = payload.calendarEventOrigin ?? ""
            todo.calendarSyncedTitle = payload.calendarSyncedTitle ?? ""
            todo.memoryNotes = payload.memoryNotes
            todo.aiRecommendedTime = payload.aiRecommendedTime
            todo.aiNeedsNotification = payload.aiNeedsNotification
            todo.aiPersonaFit = payload.aiPersonaFit
            todo.aiDetail = payload.aiDetail
            todo.aiEngine = payload.aiEngine
            todo.aiRequestedProvider = payload.aiRequestedProvider
            todo.aiFallbackReason = payload.aiFallbackReason
            todo.isFixedSchedule = payload.isFixedSchedule
            context.insert(todo)
        }

        for payload in envelope.audits {
            let placeholder = Todo()
            let audit = TaskAuditEvent(from: placeholder)
            audit.id = payload.id
            audit.todoID = payload.todoID ?? audit.id
            audit.createdAt = payload.createdAt
            audit.completedAt = payload.completedAt
            audit.deletedAt = payload.deletedAt
            audit.sourceType = payload.sourceType
            audit.triageType = payload.triageType
            audit.wasFixedSchedule = payload.wasFixedSchedule
            audit.hadDueDate = payload.hadDueDate
            audit.dueDate = payload.dueDate
            audit.tags = payload.tags ?? []
            context.insert(audit)
        }
        for payload in envelope.behaviorEvents ?? [] {
            let event = TaskBehaviorEvent(
                todo: Todo(),
                type: TaskBehaviorEventType(rawValue: payload.eventTypeRaw) ?? .created,
                actor: TaskBehaviorActor(rawValue: payload.actorRaw) ?? .system,
                occurredAt: payload.occurredAt
            )
            event.id = payload.id
            event.todoID = payload.todoID
            event.todoCreatedAt = payload.todoCreatedAt
            event.eventTypeRaw = payload.eventTypeRaw
            event.actorRaw = payload.actorRaw
            event.sourceType = payload.sourceType
            event.triageType = payload.triageType
            event.wasFixedSchedule = payload.wasFixedSchedule
            event.beforeCompletion = payload.beforeCompletion
            event.afterCompletion = payload.afterCompletion
            event.beforeDueDate = payload.beforeDueDate
            event.afterDueDate = payload.afterDueDate
            event.beforeManualPriority = payload.beforeManualPriority
            event.afterManualPriority = payload.afterManualPriority
            event.beforeComputedPriority = payload.beforeComputedPriority
            event.afterComputedPriority = payload.afterComputedPriority
            context.insert(event)
        }

        for payload in envelope.analyses {
            let analysis = MemoryAnalysis(
                summary: payload.summary,
                insights: payload.insights,
                fastTags: payload.fastTags,
                overdueRate: payload.overdueRate,
                productiveHour: payload.productiveHour,
                recordTitle: payload.recordTitle ?? "",
                accessScopeSummary: payload.accessScopeSummary ?? "",
                processorDescription: payload.processorDescription ?? ""
            )
            analysis.id = payload.id
            analysis.createdAt = payload.createdAt
            analysis.analysisVersion = payload.analysisVersion ?? 1
            analysis.windowStart = payload.windowStart
            analysis.windowEnd = payload.windowEnd
            analysis.sampleCount = payload.sampleCount ?? 0
            analysis.effectiveSampleSize = payload.effectiveSampleSize ?? 0
            analysis.confidenceRaw = payload.confidenceRaw ?? BehaviorConfidence.insufficient.rawValue
            analysis.behaviorProfileData = payload.behaviorProfileData ?? Data()
            context.insert(analysis)
        }

        try context.save()
        let restoredTodos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        Task { @MainActor in
            await TodoEligibilityReconciler.shared.reconcileAll(restoredTodos)
        }
    }
}
