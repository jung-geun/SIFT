import Foundation
import Combine

@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()
    static let learningEnabledKey = "pieroot.todo.routineLearningEnabled"
    static let didChangeNotification = Notification.Name("pieroot.todo.routineStoreDidCommit")
    private(set) var changeGeneration: UInt64 = 0

    @Published private(set) var routines: [LearnedRoutine] = []
    @Published private(set) var feedback: [RoutineFeedback] = []
    @Published private(set) var pendingAcceptances: [RoutineAcceptance] = []
    @Published private(set) var errorMessage: String?

    // Version 1's arrays remain readable. Optional-on-disk cloud metadata migrates lazily
    // on the first successful atomic write; no sidecar can get ahead of the journal.
    private nonisolated struct CloudState: Codable {
        var routines: [LearnedRoutine] = []
        var tombstones: [String] = []
        // Device-local ownership, deliberately never uploaded. Only the originating
        // device can interpret an absent task as a crash before its SwiftData save.
        var localAcceptanceIDs: [UUID] = []
        // Imported candidates must not be deleted merely because this device has
        // not received the other peer's completion evidence yet.
        var importedRoutineIDs: [UUID] = []
    }

    private nonisolated struct Snapshot: Codable {
        var version = 1
        var routines: [LearnedRoutine] = []
        var feedback: [RoutineFeedback] = []
        var pendingAcceptances: [RoutineAcceptance] = []
        var cloud = CloudState()

        init() {}

        private enum CodingKeys: String, CodingKey {
            case version, routines, feedback, pendingAcceptances, cloud
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            routines = try values.decode([LearnedRoutine].self, forKey: .routines)
            feedback = try values.decode([RoutineFeedback].self, forKey: .feedback)
            pendingAcceptances = try values.decode([RoutineAcceptance].self, forKey: .pendingAcceptances)
            cloud = try values.decodeIfPresent(CloudState.self, forKey: .cloud) ??
                CloudState(routines: routines, localAcceptanceIDs: pendingAcceptances.map(\.id))
        }
    }

    private nonisolated enum CloudKind: String {
        case routine = "0-routine", feedback = "1-feedback", acceptance = "2-acceptance"

        func key(_ id: UUID) -> String { "routine/\(rawValue)/\(id.uuidString.lowercased())" }
    }

    private var snapshot = Snapshot()
    private var canReadStore = true
    private let fileURL: URL
    private let defaults: UserDefaults
    private let writeData: (Data, URL) throws -> Void

    var isLearningEnabled: Bool { defaults.bool(forKey: Self.learningEnabledKey) }

    /// The injectable writer must either atomically replace the file or throw before replacement.
    /// It is used by isolated tests; the production writer never falls back to unprotected storage.
    init(fileURL: URL? = nil, defaults: UserDefaults = .standard,
         writer: ((Data, URL) throws -> Void)? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalRoutines", isDirectory: true).appendingPathComponent("routines.json")
        self.defaults = defaults
        self.writeData = writer ?? Self.writeProtected
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                var loaded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: self.fileURL))
                try Self.validate(loaded)
                try Self.project(&loaded)
                snapshot = loaded
                publish()
            }
        } catch {
            canReadStore = false
            errorMessage = RoutineStoreError.storeUnavailable.errorDescription
        }
    }

    /// Main integration contract:
    /// - Exclude file/LocalRoutines/routines.json from portable file capture/apply.
    /// - Merge this capture into BOTH the engine's payloads and digest maps on every
    ///   pass (not a SwiftData-only dirty cache); route routine/* here before model/file apply.
    /// - Await MainActor application before advancing the engine journal. Propagate errors;
    ///   an unreadable store is not an empty capture. Never overwrite/reload the raw file.
    /// - Missing captured identities mean deletion, not an authoritative empty collection.
    ///   Keep the engine's deletion journal, including across account rejoin.
    /// Parents sort before feedback, which sorts before reservations. Children received
    /// first are durably staged in the original arrays and captured without being lost.
    /// Capture/restore never fetches, inserts or deletes Todo rows and never changes consent.
    nonisolated static func isCloudRecordKey(_ key: String) -> Bool { key.hasPrefix("routine/") }

    func captureCloudRecords() throws -> [String: Data] {
        guard canReadStore else { throw RoutineStoreError.storeUnavailable }
        let encoder = Self.cloudEncoder()
        var result: [String: Data] = [:]
        for value in snapshot.cloud.routines { result[CloudKind.routine.key(value.id)] = try encoder.encode(value) }
        for value in snapshot.feedback { result[CloudKind.feedback.key(value.id)] = try encoder.encode(value) }
        for value in snapshot.pendingAcceptances { result[CloudKind.acceptance.key(value.id)] = try encoder.encode(value) }
        return result
    }

    func applyCloudRecord(key: String, payload: Data?) throws {
        guard canReadStore else { throw RoutineStoreError.storeUnavailable }
        let (kind, id) = try Self.parseCloudKey(key)
        var next = snapshot
        if let payload {
            // Identity deletion is permanent. A fresh learned routine gets a new UUID;
            // replaying a stale peer's old payload must not resurrect a deleted identity.
            guard !next.cloud.tombstones.contains(key) else { return }
            let decoder = JSONDecoder()
            switch kind {
            case .routine:
                let value = try decoder.decode(LearnedRoutine.self, from: payload)
                guard value.id == id, Self.isValid(value),
                      !next.cloud.routines.contains(where: { $0.id == id && $0.activityKey != value.activityKey }) else {
                    throw RoutineStoreError.invalidRoutine
                }
                next.cloud.routines.removeAll { $0.id == id }
                next.cloud.routines.append(value)
                if !next.cloud.importedRoutineIDs.contains(id) { next.cloud.importedRoutineIDs.append(id) }
            case .feedback:
                let value = try decoder.decode(RoutineFeedback.self, from: payload)
                guard value.id == id, Self.isValid(value) else { throw RoutineStoreError.invalidFeedback }
                if next.cloud.tombstones.contains(CloudKind.routine.key(value.routineID)) {
                    Self.tombstone(key, in: &next)
                } else {
                    next.feedback.removeAll { $0.id == id }
                    next.feedback.append(value)
                }
            case .acceptance:
                let value = try decoder.decode(RoutineAcceptance.self, from: payload)
                guard value.id == id, Self.isValid(value) else { throw RoutineStoreError.invalidFeedback }
                next.pendingAcceptances.removeAll { $0.id == id }
                next.pendingAcceptances.append(value)
            }
        } else {
            switch kind {
            case .routine:
                let activity = next.cloud.routines.first { $0.id == id }?.activityKey
                let ids = Set(next.cloud.routines.filter { $0.id == id || (activity != nil && $0.activityKey == activity) }.map(\.id)).union([id])
                Self.removeRoutines(ids, from: &next)
            case .feedback:
                next.feedback.removeAll { $0.id == id }
            case .acceptance:
                next.pendingAcceptances.removeAll { $0.id == id }
                next.cloud.localAcceptanceIDs.removeAll { $0 == id }
            }
            Self.tombstone(key, in: &next)
        }
        // One synchronous protected replacement, then one coherent live snapshot.
        try persist(next, cloudApply: true)
    }

    func setLearningEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.learningEnabledKey)
        // No refresh or implicit analysis when enabling; existing local evidence is retained.
        objectWillChange.send()
    }

    func refresh(todos: [Todo], now: Date = Date(), calendar: Calendar = .current) throws {
        guard isLearningEnabled else { throw RoutineStoreError.learningDisabled }
        var next = snapshot
        let learned = RoutineLearningService.learn(todos: todos, now: now, calendar: calendar)
        for candidate in learned {
            if let index = next.routines.firstIndex(where: { $0.activityKey == candidate.activityKey }) {
                let old = next.routines[index]
                var merged = candidate
                merged.id = old.id
                merged.isConfirmed = old.isConfirmed
                merged.hasManualOverrides = old.hasManualOverrides
                merged.isSuppressed = old.isSuppressed
                merged.isScheduleManuallySpecified = old.isScheduleManuallySpecified
                if old.hasManualOverrides {
                    merged.title = old.title
                    merged.periodDays = old.periodDays
                    merged.preferredHour = old.preferredHour
                    merged.preferredMinute = old.preferredMinute
                    merged.estimatedDurationMinutes = old.estimatedDurationMinutes
                    merged.nextOccurrence = old.nextOccurrence
                    merged.timeZoneIdentifier = old.timeZoneIdentifier
                }
                next.routines[index] = merged
            } else {
                next.routines.append(candidate)
            }
        }
        // Confirmed records survive disappearing evidence; nothing is inferred from deleted rows.
        let learnedKeys = Set(learned.map(\.activityKey))
        next.routines.removeAll { routine in
            !routine.isConfirmed && !learnedKeys.contains(routine.activityKey) &&
                !snapshot.pendingAcceptances.contains(where: {
                    Self.activityKey(for: $0.routineID, in: snapshot) == routine.activityKey
                })
                && !snapshot.cloud.routines.contains(where: {
                    $0.activityKey == routine.activityKey && snapshot.cloud.importedRoutineIDs.contains($0.id)
                })
        }
        next.routines.sort { $0.activityKey < $1.activityKey }
        try persist(next)
    }

    func confirm(_ routine: LearnedRoutine) throws {
        guard Self.isValid(routine), let index = snapshot.routines.firstIndex(where: { $0.id == routine.id }),
              snapshot.routines[index].activityKey == routine.activityKey else { throw RoutineStoreError.invalidRoutine }
        guard !snapshot.pendingAcceptances.contains(where: { Self.sameRoutine($0.routineID, routine.id, in: snapshot) }) else {
            throw RoutineStoreError.duplicateOccurrence
        }
        var next = snapshot
        let old = snapshot.routines[index]
        var edited = old
        edited.title = routine.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.periodDays = routine.periodDays
        edited.preferredHour = routine.preferredHour
        edited.preferredMinute = routine.preferredMinute
        edited.estimatedDurationMinutes = routine.estimatedDurationMinutes
        edited.nextOccurrence = routine.nextOccurrence
        edited.timeZoneIdentifier = routine.timeZoneIdentifier
        edited.isScheduleManuallySpecified = old.isScheduleManuallySpecified ||
            old.periodDays != routine.periodDays || old.preferredHour != routine.preferredHour ||
            old.preferredMinute != routine.preferredMinute || old.nextOccurrence != routine.nextOccurrence
        guard edited.confidence >= RoutineLearningService.minimumPredictionConfidence || edited.isScheduleManuallySpecified else {
            throw RoutineStoreError.unreliableSchedule
        }
        edited.isConfirmed = true
        edited.hasManualOverrides = true
        edited.isSuppressed = false
        edited.updatedAt = Date()
        next.routines[index] = edited
        try persist(next)
    }

    func delete(_ id: UUID) throws {
        // Do not destroy an acceptance journal while a cross-store task save is unresolved.
        guard !snapshot.pendingAcceptances.contains(where: { Self.sameRoutine($0.routineID, id, in: snapshot) }) else {
            throw RoutineStoreError.duplicateOccurrence
        }
        var next = snapshot
        let activity = Self.activityKey(for: id, in: snapshot)
        next.routines.removeAll { $0.id == id || (activity != nil && $0.activityKey == activity) }
        next.feedback.removeAll { Self.sameRoutine($0.routineID, id, in: snapshot) }
        try persist(next)
    }

    func deleteAll() throws {
        // This is an explicit privacy deletion, including reservations and feedback. The parent
        // must serialize it with acceptance and delete any tasks separately through SwiftData.
        var next = Snapshot()
        next.cloud.tombstones = snapshot.cloud.tombstones
        for key in Self.knownKeys(in: snapshot) { Self.tombstone(key, in: &next) }
        try persist(next, allowUnreadableReplacement: true, cloudApply: true)
    }

    func record(_ entry: RoutineFeedback) throws {
        guard isLearningEnabled else { throw RoutineStoreError.learningDisabled }
        var next = snapshot
        try appendFeedback(entry, to: &next)
        try persist(next)
    }

    func suggestions(now: Date, todos: [Todo], calendar: Calendar = .current) -> [RoutineSuggestion] {
        guard isLearningEnabled, canReadStore else { return [] }
        return snapshot.routines.filter {
            $0.isConfirmed && !$0.isSuppressed &&
            ($0.confidence >= RoutineLearningService.minimumPredictionConfidence || $0.isScheduleManuallySpecified)
        }.compactMap { routine in
            var local = calendar
            if let zone = TimeZone(identifier: routine.timeZoneIdentifier) { local.timeZone = zone }
            let decisions = snapshot.feedback.filter { Self.sameRoutine($0.routineID, routine.id, in: snapshot) }
            // A postponed item keeps its original anchor, even if moved to another day/cycle.
            let postponed = decisions.filter { $0.action == .postponed }.sorted(by: Self.newerFeedback).first {
                entry in !decisions.contains { $0.occurrence == entry.occurrence && ($0.action == .accepted || $0.action == .rejected) }
            }
            let occurrence: Date
            let preferred: Date
            if let postponed, let applied = postponed.appliedTime {
                occurrence = postponed.occurrence
                preferred = max(now, applied)
            } else {
                var day = local.startOfDay(for: routine.nextOccurrence)
                let today = local.startOfDay(for: now)
                if day < today {
                    let days = local.dateComponents([.day], from: day, to: today).day ?? 0
                    let cycles = (days + routine.periodDays - 1) / routine.periodDays
                    guard let advanced = local.date(byAdding: .day, value: cycles * routine.periodDays, to: day) else { return nil }
                    day = advanced
                }
                occurrence = day
                guard let time = RoutineLearningService.localTime(on: day, hour: routine.preferredHour,
                                                                  minute: routine.preferredMinute, calendar: local) else { return nil }
                preferred = max(now, time)
            }
            let suggestion = RoutineSuggestion(routineID: routine.id, title: routine.title, occurrence: occurrence,
                                               preferredStart: preferred, estimatedDurationMinutes: routine.estimatedDurationMinutes)
            guard !decisions.contains(where: { $0.occurrence == occurrence && ($0.action == .accepted || $0.action == .rejected) }),
                  !snapshot.pendingAcceptances.contains(where: {
                      Self.sameRoutine($0.routineID, routine.id, in: snapshot) && $0.occurrence == occurrence
                  }),
                  !hasMatchingTask(suggestion, routine: routine, postponedTime: postponed?.appliedTime,
                                   todos: todos, calendar: local) else { return nil }
            return suggestion
        }.sorted {
            $0.preferredStart == $1.preferredStart ? $0.id < $1.id : $0.preferredStart < $1.preferredStart
        }
    }

    /// 1. Persist this reservation before inserting/saving the task. Use its todoID and sourceRef.
    /// 2. Save SwiftData. On success commitAcceptance; on save failure roll back SwiftData then cancel.
    /// A failed commit must NOT delete the saved task: the reservation blocks duplicates until reconciliation.
    func beginAcceptance(_ suggestion: RoutineSuggestion, todos: [Todo], appliedTime: Date,
                         todoID: UUID, now: Date = Date(), calendar: Calendar = .current) throws -> RoutineAcceptance {
        guard isLearningEnabled else { throw RoutineStoreError.learningDisabled }
        guard appliedTime.timeIntervalSince1970.isFinite, appliedTime >= now else { throw RoutineStoreError.invalidFeedback }
        guard let current = suggestions(now: now, todos: todos, calendar: calendar).first(where: { $0.id == suggestion.id }),
              current.title == suggestion.title, current.estimatedDurationMinutes == suggestion.estimatedDurationMinutes,
              (current.preferredStart == suggestion.preferredStart ||
                (suggestion.preferredStart <= now && current.preferredStart == now)) else { throw RoutineStoreError.staleSuggestion }
        guard !snapshot.pendingAcceptances.contains(where: { $0.todoID == todoID }) else { throw RoutineStoreError.duplicateOccurrence }
        let reservation = RoutineAcceptance(routineID: suggestion.routineID, occurrence: suggestion.occurrence,
                                            suggestedTime: suggestion.preferredStart, appliedTime: appliedTime,
                                            todoID: todoID, recordedAt: now)
        var next = snapshot
        next.pendingAcceptances.append(reservation)
        next.cloud.localAcceptanceIDs.append(reservation.id)
        try persist(next)
        return reservation
    }

    func commitAcceptance(_ id: UUID) throws {
        guard let reservation = snapshot.pendingAcceptances.first(where: { $0.id == id }) else {
            throw RoutineStoreError.acceptanceNotFound
        }
        var next = snapshot
        try finishAcceptance(reservation, appliedTime: reservation.appliedTime,
                             todoID: reservation.todoID, recordedAt: reservation.recordedAt, in: &next)
        // Complete the user's already-started transaction even if opt-in changed during SwiftData save.
        try persist(next)
    }

    func cancelAcceptance(_ id: UUID) throws {
        guard snapshot.pendingAcceptances.contains(where: { $0.id == id }) else { throw RoutineStoreError.acceptanceNotFound }
        var next = snapshot
        next.pendingAcceptances.removeAll { $0.id == id }
        try persist(next)
    }

    /// Call only after a successful, complete fresh task fetch, never on a fetch failure/partial list.
    /// A restored reservation is NOT cancelled just because its task has not synced yet.
    /// Originating-device reservations retain crash-before-save cancellation semantics.
    func reconcileAcceptances(todos: [Todo], now: Date = Date()) throws {
        var next = snapshot
        for reservation in snapshot.pendingAcceptances {
            let task = todos.first { $0.id == reservation.todoID } ??
                todos.first { $0.sourceRef == reservation.sourceRef }
            if let task {
                // An out-of-order parent must arrive before its accepted feedback can
                // be materialized. A deleted parent needs only its journal resolved.
                guard Self.activityKey(for: reservation.routineID, in: next) != nil ||
                    next.cloud.tombstones.contains(CloudKind.routine.key(reservation.routineID)) else { continue }
                try finishAcceptance(reservation, appliedTime: task.startDate ?? reservation.appliedTime,
                                     todoID: task.id, recordedAt: now, in: &next)
            } else if next.cloud.localAcceptanceIDs.contains(reservation.id) {
                next.pendingAcceptances.removeAll { $0.id == reservation.id }
            }
        }
        if next.pendingAcceptances != snapshot.pendingAcceptances { try persist(next) }
    }

    private func finishAcceptance(_ reservation: RoutineAcceptance, appliedTime: Date,
                                  todoID: UUID, recordedAt: Date, in next: inout Snapshot) throws {
        next.pendingAcceptances.removeAll { $0.id == reservation.id }
        if next.cloud.tombstones.contains(CloudKind.routine.key(reservation.routineID)) { return }
        // The reservation UUID is also the accepted-feedback UUID, in a different
        // namespace. Two peers repairing the same crash cannot invent two decisions.
        guard !next.feedback.contains(where: { $0.id == reservation.id }) else { return }
        try appendFeedback(RoutineFeedback(id: reservation.id, routineID: reservation.routineID,
                                          occurrence: reservation.occurrence, action: .accepted,
                                          suggestedTime: reservation.suggestedTime, appliedTime: appliedTime,
                                          todoID: todoID, recordedAt: recordedAt), to: &next,
                           completingReservation: true)
    }

    private func appendFeedback(_ entry: RoutineFeedback, to next: inout Snapshot,
                                completingReservation: Bool = false) throws {
        guard let index = next.routines.firstIndex(where: {
            Self.sameRoutine($0.id, entry.routineID, in: next) && ($0.isConfirmed || completingReservation)
        }), Self.isValid(entry),
              !next.feedback.contains(where: { $0.id == entry.id }) else { throw RoutineStoreError.invalidFeedback }
        var occurrenceCalendar = Calendar(identifier: .gregorian)
        occurrenceCalendar.timeZone = TimeZone(identifier: next.routines[index].timeZoneIdentifier) ?? .current
        let hasPostponedAnchor = next.feedback.contains {
            Self.sameRoutine($0.routineID, entry.routineID, in: next)
                && $0.occurrence == entry.occurrence && $0.action == .postponed
        }
        guard completingReservation || hasPostponedAnchor || occurrenceCalendar.startOfDay(for: entry.occurrence) == entry.occurrence else {
            throw RoutineStoreError.invalidFeedback
        }
        guard completingReservation || (!next.feedback.contains(where: {
            Self.sameRoutine($0.routineID, entry.routineID, in: next) && $0.occurrence == entry.occurrence &&
                ($0.action == .accepted || $0.action == .rejected)
        }) && !next.pendingAcceptances.contains(where: {
            Self.sameRoutine($0.routineID, entry.routineID, in: next) && $0.occurrence == entry.occurrence
        })) else {
            throw RoutineStoreError.duplicateOccurrence
        }
        if entry.action != .rejected, let applied = entry.appliedTime {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(identifier: next.routines[index].timeZoneIdentifier) ?? .current
            next.routines[index].preferredHour = local.component(.hour, from: applied)
            next.routines[index].preferredMinute = local.component(.minute, from: applied)
            next.routines[index].hasManualOverrides = true
        }
        next.feedback.append(entry)
        next.routines[index].updatedAt = entry.recordedAt
        let recent = next.feedback.filter {
            Self.sameRoutine($0.routineID, entry.routineID, in: next) && $0.action != .postponed
        }.sorted(by: Self.newerFeedback).prefix(3)
        if recent.count == 3 && recent.allSatisfy({ $0.action == .rejected }) {
            next.routines[index].isSuppressed = true
        }
    }

    private func hasMatchingTask(_ suggestion: RoutineSuggestion, routine: LearnedRoutine,
                                 postponedTime: Date?, todos: [Todo], calendar: Calendar) -> Bool {
        let aliases = snapshot.cloud.routines.filter { $0.activityKey == routine.activityKey }.map(\.id)
        let references = Set(aliases.map { RoutineSuggestion.sourceRef(routineID: $0, occurrence: suggestion.occurrence) })
        let todoIDs = Set(snapshot.feedback.filter {
            Self.sameRoutine($0.routineID, routine.id, in: snapshot) && $0.occurrence == suggestion.occurrence
        }.compactMap(\.todoID))
        return todos.contains { task in
            if references.contains(task.sourceRef) || todoIDs.contains(task.id) { return true }
            guard task.triageStatus == TodoTriage.todo.rawValue,
                  RoutineLearningService.activityKey(task.title) == routine.activityKey ||
                    RoutineLearningService.activityKey(task.title) == RoutineLearningService.activityKey(routine.title) else { return false }
            if task.isCompleted {
                guard let completed = task.completedAt else { return false }
                return calendar.isDate(completed, inSameDayAs: suggestion.occurrence) ||
                    calendar.isDate(completed, inSameDayAs: suggestion.preferredStart) ||
                    postponedTime.map { calendar.isDate(completed, inSameDayAs: $0) } == true
            }
            guard let scheduled = task.startDate ?? task.dueDate else { return true }
            return calendar.isDate(scheduled, inSameDayAs: suggestion.occurrence) ||
                calendar.isDate(scheduled, inSameDayAs: suggestion.preferredStart)
        }
    }

    private static func isValid(_ routine: LearnedRoutine) -> Bool {
        !routine.activityKey.isEmpty && !routine.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...90).contains(routine.periodDays) && (0...23).contains(routine.preferredHour) &&
        (0...59).contains(routine.preferredMinute) && (1...1440).contains(routine.estimatedDurationMinutes) &&
        routine.sampleCount >= RoutineLearningService.minimumDistinctDays && routine.confidence.isFinite &&
        (0...1).contains(routine.confidence) && routine.evidenceStart <= routine.evidenceEnd &&
        routine.evidenceStart.timeIntervalSince1970.isFinite && routine.evidenceEnd.timeIntervalSince1970.isFinite &&
        routine.updatedAt.timeIntervalSince1970.isFinite && routine.nextOccurrence.timeIntervalSince1970.isFinite &&
        TimeZone(identifier: routine.timeZoneIdentifier) != nil
    }

    private static func cloudEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func parseCloudKey(_ key: String) throws -> (CloudKind, UUID) {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "routine",
              let kind = CloudKind(rawValue: String(parts[1])), let id = UUID(uuidString: String(parts[2])),
              kind.key(id) == key else { throw RoutineStoreError.storeUnavailable }
        return (kind, id)
    }

    private static func activityKey(for id: UUID, in state: Snapshot) -> String? {
        state.cloud.routines.first { $0.id == id }?.activityKey
    }

    private static func sameRoutine(_ first: UUID, _ second: UUID, in state: Snapshot) -> Bool {
        if first == second { return true }
        guard let key = activityKey(for: first, in: state) else { return false }
        return key == activityKey(for: second, in: state)
    }

    private static func newerFeedback(_ first: RoutineFeedback, _ second: RoutineFeedback) -> Bool {
        first.recordedAt == second.recordedAt ? first.id.uuidString > second.id.uuidString : first.recordedAt > second.recordedAt
    }

    private static func isValid(_ value: RoutineFeedback) -> Bool {
        guard value.occurrence.timeIntervalSince1970.isFinite,
              value.suggestedTime.timeIntervalSince1970.isFinite, value.recordedAt.timeIntervalSince1970.isFinite,
              value.appliedTime.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return false }
        switch value.action {
        case .accepted: return value.appliedTime != nil && value.todoID != nil
        case .rejected: return true
        case .postponed:
            guard let applied = value.appliedTime else { return false }
            return applied > value.suggestedTime && applied >= value.recordedAt
        }
    }

    private static func isValid(_ value: RoutineAcceptance) -> Bool {
        [value.occurrence, value.suggestedTime, value.appliedTime, value.recordedAt]
            .allSatisfy { $0.timeIntervalSince1970.isFinite } && value.appliedTime >= value.recordedAt
    }

    private static func knownKeys(in state: Snapshot) -> Set<String> {
        Set(state.cloud.routines.map { CloudKind.routine.key($0.id) } +
            state.feedback.map { CloudKind.feedback.key($0.id) } +
            state.pendingAcceptances.map { CloudKind.acceptance.key($0.id) })
    }

    private static func tombstone(_ key: String, in state: inout Snapshot) {
        if !state.cloud.tombstones.contains(key) { state.cloud.tombstones.append(key) }
    }

    private static func removeRoutines(_ ids: Set<UUID>, from state: inout Snapshot) {
        for id in ids { tombstone(CloudKind.routine.key(id), in: &state) }
        for entry in state.feedback where ids.contains(entry.routineID) {
            tombstone(CloudKind.feedback.key(entry.id), in: &state)
        }
        state.cloud.routines.removeAll { ids.contains($0.id) }
        state.feedback.removeAll { ids.contains($0.routineID) }
        // Remote deletion must not destroy an in-flight task-save journal. Reservations
        // survive until task-ID reconciliation, explicit cancellation or deleteAll.
    }

    private static func resolveAcceptedJournals(in state: inout Snapshot) {
        let accepted = state.feedback.filter { $0.action == .accepted }
        let taskIDs = Set(accepted.compactMap(\.todoID))
        // New commits share their UUID with the reservation. Persist the retirement
        // even if that reservation has not arrived; older feedback can also prove
        // completion by todoID without rewriting its original feedback UUID.
        for entry in accepted { tombstone(CloudKind.acceptance.key(entry.id), in: &state) }
        for entry in state.pendingAcceptances where taskIDs.contains(entry.todoID) {
            tombstone(CloudKind.acceptance.key(entry.id), in: &state)
        }
        let retired = Set(state.cloud.tombstones)
        state.pendingAcceptances.removeAll { retired.contains(CloudKind.acceptance.key($0.id)) }
    }

    private static func validate(_ state: Snapshot) throws {
        guard state.version == 1, state.routines.allSatisfy(isValid), state.cloud.routines.allSatisfy(isValid),
              state.feedback.allSatisfy(isValid), state.pendingAcceptances.allSatisfy(isValid),
              Set(state.routines.map(\.id)).count == state.routines.count,
              Set(state.routines.map(\.activityKey)).count == state.routines.count,
              Set(state.cloud.routines.map(\.id)).count == state.cloud.routines.count,
              Set(state.feedback.map(\.id)).count == state.feedback.count,
              Set(state.pendingAcceptances.map(\.id)).count == state.pendingAcceptances.count,
              Set(state.cloud.localAcceptanceIDs).isSubset(of: Set(state.pendingAcceptances.map(\.id))),
              Set(state.cloud.importedRoutineIDs).isSubset(of: Set(state.cloud.routines.map(\.id))),
              Set(state.cloud.tombstones).isDisjoint(with: knownKeys(in: state)) else {
            throw RoutineStoreError.storeUnavailable
        }
        for key in state.cloud.tombstones { _ = try parseCloudKey(key) }
    }

    /// Deterministic read projection: the smallest UUID names each activity, while
    /// the newest updatedAt supplies its fields (canonical JSON bytes break ties).
    /// Raw variants and child references are NEVER rewritten, retaining all provenance.
    /// Concurrent edits of the SAME record remain the engine's per-key LWW conflict;
    /// different feedback/reservation UUIDs always union, even for the same occurrence.
    private static func project(_ state: inout Snapshot) throws {
        let encoder = cloudEncoder()
        let groups = Dictionary(grouping: state.cloud.routines, by: \.activityKey)
        let activities = Dictionary(uniqueKeysWithValues: state.cloud.routines.map { ($0.id, $0.activityKey) })
        let decisions = Dictionary(grouping: state.feedback, by: { activities[$0.routineID] ?? "" })
        var projected: [LearnedRoutine] = []
        for key in groups.keys.sorted() {
            guard let variants = groups[key], let canonicalID = variants.map(\.id).min(by: { $0.uuidString < $1.uuidString }) else { continue }
            let ranked = try variants.map { (value: $0, bytes: try encoder.encode($0)) }
            guard var routine = ranked.max(by: {
                $0.value.updatedAt == $1.value.updatedAt ? $0.bytes.lexicographicallyPrecedes($1.bytes) :
                    $0.value.updatedAt < $1.value.updatedAt
            })?.value else { continue }
            routine.id = canonicalID
            let history = (decisions[key] ?? []).sorted(by: newerFeedback)
            if let timing = history.first(where: { $0.action != .rejected }),
               timing.recordedAt >= routine.updatedAt, let applied = timing.appliedTime {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: routine.timeZoneIdentifier) ?? .current
                routine.preferredHour = calendar.component(.hour, from: applied)
                routine.preferredMinute = calendar.component(.minute, from: applied)
                routine.hasManualOverrides = true
            }
            let recent = history.filter { $0.action != .postponed }.prefix(3)
            if recent.count == 3, recent.allSatisfy({ $0.action == .rejected }),
               let latest = recent.first, latest.recordedAt >= routine.updatedAt { routine.isSuppressed = true }
            projected.append(routine)
        }
        state.routines = projected
        state.cloud.routines.sort { $0.id.uuidString < $1.id.uuidString }
        state.feedback.sort { $0.recordedAt == $1.recordedAt ? $0.id.uuidString < $1.id.uuidString : $0.recordedAt < $1.recordedAt }
        state.pendingAcceptances.sort { $0.id.uuidString < $1.id.uuidString }
        state.cloud.tombstones.sort()
        state.cloud.localAcceptanceIDs.sort { $0.uuidString < $1.uuidString }
        state.cloud.importedRoutineIDs.sort { $0.uuidString < $1.uuidString }
    }

    private func persist(_ proposed: Snapshot, allowUnreadableReplacement: Bool = false,
                         cloudApply: Bool = false) throws {
        guard canReadStore || allowUnreadableReplacement else { throw RoutineStoreError.storeUnavailable }
        var next = proposed
        if !cloudApply {
            // Local APIs operate on the canonical live view. Reflect only actual edits
            // into raw variants; a read projection must never overwrite another alias.
            let remaining = Set(next.routines.map(\.activityKey))
            let removed = Set(snapshot.cloud.routines.filter { !remaining.contains($0.activityKey) }.map(\.id))
            Self.removeRoutines(removed, from: &next)
            for routine in proposed.routines where snapshot.routines.first(where: { $0.id == routine.id }) != routine {
                next.cloud.routines.removeAll { $0.id == routine.id }
                next.cloud.routines.append(routine)
            }
            for key in Self.knownKeys(in: snapshot).subtracting(Self.knownKeys(in: next)) {
                Self.tombstone(key, in: &next)
            }
        }
        Self.resolveAcceptedJournals(in: &next)
        let pendingIDs = Set(next.pendingAcceptances.map(\.id))
        next.cloud.localAcceptanceIDs.removeAll { !pendingIDs.contains($0) }
        let routineIDs = Set(next.cloud.routines.map(\.id))
        next.cloud.importedRoutineIDs.removeAll { !routineIDs.contains($0) }
        try Self.project(&next)
        try Self.validate(next)
        do {
            try writeData(Self.cloudEncoder().encode(next), fileURL)
            snapshot = next
            canReadStore = true
            errorMessage = nil
            changeGeneration &+= 1
            publish()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        } catch {
            errorMessage = RoutineStoreError.saveFailed.errorDescription
            throw RoutineStoreError.saveFailed
        }
    }

    private func publish() {
        routines = snapshot.routines
        // Orphan feedback stays on disk and in captures, but is not actionable until
        // its parent arrives. Reservations remain visible even while staged/deleted.
        feedback = snapshot.feedback.filter { Self.activityKey(for: $0.routineID, in: snapshot) != nil }
        pendingAcceptances = snapshot.pendingAcceptances
    }

    private static func writeProtected(_ data: Data, to fileURL: URL) throws {
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        // Atomic replacement and protection happen together: no throwing work after commit.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
