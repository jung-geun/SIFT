import SwiftData
import Foundation
import SwiftData

private struct FirebaseSnapshotEnvelope: Codable {
    let exportedAt: Date
    let personas: [FirebaseSnapshotPersona]
    let todos: [FirebaseSnapshotTodo]
    let audits: [FirebaseSnapshotAudit]
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
    let triageStatus: String
    let tags: [String]
    let calendarEventID: String?
    let calendarEventExternalID: String
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
    let createdAt: Date
    let completedAt: Date?
    let deletedAt: Date
    let sourceType: String
    let triageType: String
    let wasFixedSchedule: Bool
    let hadDueDate: Bool
}

private struct FirebaseSnapshotAnalysis: Codable {
    let id: UUID
    let summary: String
    let insights: [String]
    let fastTags: [String]
    let overdueRate: Double
    let productiveHour: Int?
    let createdAt: Date
}

enum FirebaseSnapshotStore {
    @MainActor
    static func exportJSON(context: ModelContext) throws -> String {
        let personas = (try? context.fetch(FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let audits = (try? context.fetch(FetchDescriptor<TaskAuditEvent>())) ?? []
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
                    triageStatus: $0.triageStatus,
                    tags: $0.tags,
                    calendarEventID: $0.calendarEventID,
                    calendarEventExternalID: $0.calendarEventExternalID,
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
                    createdAt: $0.createdAt,
                    completedAt: $0.completedAt,
                    deletedAt: $0.deletedAt,
                    sourceType: $0.sourceType,
                    triageType: $0.triageType,
                    wasFixedSchedule: $0.wasFixedSchedule,
                    hadDueDate: $0.hadDueDate
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
                    createdAt: $0.createdAt
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
            todo.triageStatus = payload.triageStatus
            todo.tags = payload.tags
            todo.calendarEventID = payload.calendarEventID
            todo.calendarEventExternalID = payload.calendarEventExternalID
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
            audit.createdAt = payload.createdAt
            audit.completedAt = payload.completedAt
            audit.deletedAt = payload.deletedAt
            audit.sourceType = payload.sourceType
            audit.triageType = payload.triageType
            audit.wasFixedSchedule = payload.wasFixedSchedule
            audit.hadDueDate = payload.hadDueDate
            context.insert(audit)
        }

        for payload in envelope.analyses {
            let analysis = MemoryAnalysis(
                summary: payload.summary,
                insights: payload.insights,
                fastTags: payload.fastTags,
                overdueRate: payload.overdueRate,
                productiveHour: payload.productiveHour
            )
            analysis.id = payload.id
            analysis.createdAt = payload.createdAt
            context.insert(analysis)
        }

        try context.save()
    }
}
