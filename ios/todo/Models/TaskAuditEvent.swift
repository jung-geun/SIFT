import Foundation
import SwiftData

/// 사용자가 삭제한 할 일의 lifecycle 스냅샷.
///
/// 삭제된 todo는 SwiftData에서 hard-delete되어 기록이 사라진다.
/// TaskAuditEvent는 삭제 시점의 lifecycle 정보를 보존해 페르소나·패턴 분석에 활용한다.
///
/// 기록 범위: **사용자 주도 삭제만** (TodoListView.deleteTodo choke point).
/// 자동 만료 sweep(TodoListView 기동 시 마감 경과분 삭제, CalendarService 만료 sweep)에는
/// 기록하지 않는다 — 자동 정리는 사용자 의도가 아니라 관리 노이즈이기 때문.
///
/// CloudKit 호환: 비옵셔널+기본값 또는 옵셔널만 사용, @Attribute(.unique) 금지.
@Model
final class TaskAuditEvent {

    // MARK: - Identity

    var id: UUID = UUID()

    // MARK: - Lifecycle 타임스탬프

    /// 원본 todo 등록 시각
    var createdAt: Date = Date()
    /// 완료 후 삭제된 경우 존재, 미완료 삭제는 nil
    var completedAt: Date?
    /// 삭제 시각 (스냅샷 생성 시각)
    var deletedAt: Date = Date()

    // MARK: - 태스크 종류

    /// TodoSource.rawValue — manual / email / calendar
    var sourceType: String = ""
    /// TodoTriage.rawValue — todo(진행중) / review(등록 대기열)
    var triageType: String = ""
    /// 반복(isFixedSchedule) 일정 여부
    var wasFixedSchedule: Bool = false
    /// 마감일 존재 여부
    var hadDueDate: Bool = false

    // MARK: - 파생 통계 (저장하지 않음, 분석 시 계산)

    /// 삭제까지 소요 시간(초). `deletedAt − createdAt`.
    var timeToDelete: Double {
        deletedAt.timeIntervalSince(createdAt)
    }

    /// 완료까지 소요 시간(초). 완료 후 삭제된 경우만 값 존재. `completedAt − createdAt`.
    var timeToComplete: Double? {
        guard let c = completedAt else { return nil }
        return c.timeIntervalSince(createdAt)
    }

    // MARK: - Init

    init(from todo: Todo) {
        self.createdAt        = todo.createdAt
        self.completedAt      = todo.completedAt
        self.deletedAt        = Date()
        self.sourceType       = todo.source
        self.triageType       = todo.triageStatus
        self.wasFixedSchedule = todo.isFixedSchedule
        self.hadDueDate       = todo.dueDate != nil
    }
}

// MARK: - Typed behavior event log

enum TaskBehaviorEventType: String, Codable, Sendable {
    case created
    case completionChanged
    case dueDateChanged
    case priorityChanged
    case deleted
}

enum TaskBehaviorActor: String, Codable, Sendable {
    case user
    case artificialIntelligence
    case system
    case emailIngestion
    case calendarSync
    case recurrence
    case meetingImport
}

/// A typed, content-free record of a meaningful Todo state transition.
///
/// Titles, notes, tags, and external identifiers are deliberately excluded.
/// CloudKit compatibility requires defaults for nonoptional stored properties.
@Model
final class TaskBehaviorEvent {
    var id: UUID = UUID()
    var todoID: UUID = UUID()
    var occurredAt: Date = Date()
    var eventTypeRaw: String = TaskBehaviorEventType.created.rawValue
    var actorRaw: String = TaskBehaviorActor.system.rawValue
    var sourceType: String = ""
    var triageType: String = ""
    var wasFixedSchedule: Bool = false

    var beforeCompletion: Bool?
    var afterCompletion: Bool?
    var beforeDueDate: Date?
    var afterDueDate: Date?
    var beforeManualPriority: Int?
    var afterManualPriority: Int?
    var beforeComputedPriority: Double?
    var afterComputedPriority: Double?

    var eventType: TaskBehaviorEventType {
        TaskBehaviorEventType(rawValue: eventTypeRaw) ?? .created
    }

    var actor: TaskBehaviorActor {
        TaskBehaviorActor(rawValue: actorRaw) ?? .system
    }

    init(
        todo: Todo,
        type: TaskBehaviorEventType,
        actor: TaskBehaviorActor,
        occurredAt: Date
    ) {
        todoID = todo.id
        self.occurredAt = occurredAt
        eventTypeRaw = type.rawValue
        actorRaw = actor.rawValue
        sourceType = todo.source
        triageType = todo.triageStatus
        wasFixedSchedule = todo.isFixedSchedule
    }
}

/// Single insertion point for behavior telemetry. Callers mutate Todo first,
/// then record the transition with the captured before value.
@MainActor
enum TaskBehaviorRecorder {
    static func recordCreation(
        of todo: Todo,
        actor: TaskBehaviorActor,
        in context: ModelContext,
        at occurredAt: Date = Date()
    ) {
        let event = TaskBehaviorEvent(todo: todo, type: .created, actor: actor, occurredAt: occurredAt)
        event.afterCompletion = todo.isCompleted
        event.afterDueDate = todo.dueDate
        event.afterManualPriority = todo.manualPriority
        event.afterComputedPriority = todo.computedPriorityScore
        context.insert(event)
    }

    static func recordCompletionChange(
        of todo: Todo,
        from before: Bool,
        to after: Bool,
        actor: TaskBehaviorActor,
        in context: ModelContext,
        at occurredAt: Date = Date()
    ) {
        guard before != after else { return }
        let event = TaskBehaviorEvent(todo: todo, type: .completionChanged, actor: actor, occurredAt: occurredAt)
        event.beforeCompletion = before
        event.afterCompletion = after
        context.insert(event)
    }

    static func recordDueDateChange(
        of todo: Todo,
        from before: Date?,
        to after: Date?,
        actor: TaskBehaviorActor,
        in context: ModelContext,
        at occurredAt: Date = Date()
    ) {
        guard before != after else { return }
        let event = TaskBehaviorEvent(todo: todo, type: .dueDateChanged, actor: actor, occurredAt: occurredAt)
        event.beforeDueDate = before
        event.afterDueDate = after
        context.insert(event)
    }

    static func recordManualPriorityChange(
        of todo: Todo,
        from before: Int?,
        to after: Int?,
        actor: TaskBehaviorActor,
        in context: ModelContext,
        at occurredAt: Date = Date()
    ) {
        guard before != after else { return }
        let event = TaskBehaviorEvent(todo: todo, type: .priorityChanged, actor: actor, occurredAt: occurredAt)
        event.beforeManualPriority = before
        event.afterManualPriority = after
        context.insert(event)
    }

    static func recordComputedPriorityChange(
        of todo: Todo,
        from before: Double,
        to after: Double,
        actor: TaskBehaviorActor,
        in context: ModelContext,
        at occurredAt: Date = Date()
    ) {
        guard before != after else { return }
        let event = TaskBehaviorEvent(todo: todo, type: .priorityChanged, actor: actor, occurredAt: occurredAt)
        event.beforeComputedPriority = before
        event.afterComputedPriority = after
        context.insert(event)
    }

    static func recordDeletion(
        of todo: Todo,
        actor: TaskBehaviorActor,
        in context: ModelContext,
        at occurredAt: Date = Date()
    ) {
        let event = TaskBehaviorEvent(todo: todo, type: .deleted, actor: actor, occurredAt: occurredAt)
        event.beforeCompletion = todo.isCompleted
        event.beforeDueDate = todo.dueDate
        event.beforeManualPriority = todo.manualPriority
        event.beforeComputedPriority = todo.computedPriorityScore
        context.insert(event)
    }
}
