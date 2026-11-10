import Foundation
import SwiftData

/// Bounds task behavior history so the synced payload and write volume stop growing.
///
/// Both limits are measured on the timestamp the analysis actually reads:
/// - Behavior events: `occurredAt`. BehaviorAnalysisEngine uses a 90-day window.
/// - Audit events: `deletedAt`, not `createdAt`. An audit row is the deletion record;
///   a long-lived task deleted recently still feeds the analysis window.
/// Memory analysis rows are pruned by MemoryService on every save, so they are not handled here.
nonisolated enum TaskHistoryRetention {
    /// The analysis window is 90 days; 120 leaves margin for backdated events.
    static let retentionDays = 120

    /// Deletes rows older than the retention limit. Returns the number of rows removed.
    /// Deletions propagate to the cloud as tombstones through the normal sync pass.
    @discardableResult
    static func prune(in context: ModelContext, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)

        let behaviors = try context.fetch(FetchDescriptor<TaskBehaviorEvent>(
            predicate: #Predicate { $0.occurredAt < cutoff }
        ))
        for event in behaviors { context.delete(event) }

        let audits = try context.fetch(FetchDescriptor<TaskAuditEvent>(
            predicate: #Predicate { $0.deletedAt < cutoff }
        ))
        for audit in audits { context.delete(audit) }

        let removed = behaviors.count + audits.count
        if removed > 0 { try context.save() }
        return removed
    }
}
