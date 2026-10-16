import Foundation
import Combine

@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()
    static let learningEnabledKey = "pieroot.todo.routineLearningEnabled"

    @Published private(set) var routines: [LearnedRoutine] = []
    @Published private(set) var feedback: [RoutineFeedback] = []
    @Published private(set) var pendingAcceptances: [RoutineAcceptance] = []
    @Published private(set) var errorMessage: String?

    private nonisolated struct Snapshot: Codable {
        var version = 1
        var routines: [LearnedRoutine] = []
        var feedback: [RoutineFeedback] = []
        var pendingAcceptances: [RoutineAcceptance] = []
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
                let loaded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: self.fileURL))
                guard loaded.version == 1, loaded.routines.allSatisfy(Self.isValid),
                      Set(loaded.routines.map(\.id)).count == loaded.routines.count,
                      Set(loaded.routines.map(\.activityKey)).count == loaded.routines.count else {
                    throw RoutineStoreError.storeUnavailable
                }
                snapshot = loaded
                publish()
            }
        } catch {
            canReadStore = false
            errorMessage = RoutineStoreError.storeUnavailable.errorDescription
        }
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
        next.routines.removeAll { !$0.isConfirmed && !learnedKeys.contains($0.activityKey) }
        next.routines.sort { $0.activityKey < $1.activityKey }
        try persist(next)
    }

    func confirm(_ routine: LearnedRoutine) throws {
        guard Self.isValid(routine), let index = snapshot.routines.firstIndex(where: { $0.id == routine.id }),
              snapshot.routines[index].activityKey == routine.activityKey else { throw RoutineStoreError.invalidRoutine }
        guard !snapshot.pendingAcceptances.contains(where: { $0.routineID == routine.id }) else {
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
        guard !snapshot.pendingAcceptances.contains(where: { $0.routineID == id }) else {
            throw RoutineStoreError.duplicateOccurrence
        }
        var next = snapshot
        next.routines.removeAll { $0.id == id }
        next.feedback.removeAll { $0.routineID == id }
        try persist(next)
    }

    func deleteAll() throws {
        // This is an explicit privacy deletion, including reservations and feedback. The parent
        // must serialize it with acceptance and delete any tasks separately through SwiftData.
        try persist(Snapshot(), allowUnreadableReplacement: true)
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
            let decisions = snapshot.feedback.filter { $0.routineID == routine.id }
            // A postponed item keeps its original anchor, even if moved to another day/cycle.
            let postponed = decisions.filter { $0.action == .postponed }.sorted { $0.recordedAt > $1.recordedAt }.first {
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
                  !snapshot.pendingAcceptances.contains(where: { $0.sourceRef == suggestion.sourceRef }),
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
        try persist(next)
        return reservation
    }

    func commitAcceptance(_ id: UUID) throws {
        guard let reservation = snapshot.pendingAcceptances.first(where: { $0.id == id }) else {
            throw RoutineStoreError.acceptanceNotFound
        }
        var next = snapshot
        next.pendingAcceptances.removeAll { $0.id == id }
        try appendFeedback(RoutineFeedback(routineID: reservation.routineID, occurrence: reservation.occurrence,
                                          action: .accepted, suggestedTime: reservation.suggestedTime,
                                          appliedTime: reservation.appliedTime, todoID: reservation.todoID,
                                          recordedAt: reservation.recordedAt), to: &next)
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
    /// This repairs crashes both before and after the SwiftData save without creating a second task.
    func reconcileAcceptances(todos: [Todo], now: Date = Date()) throws {
        var next = snapshot
        for reservation in snapshot.pendingAcceptances {
            next.pendingAcceptances.removeAll { $0.id == reservation.id }
            if let task = todos.first(where: { $0.sourceRef == reservation.sourceRef }) {
                try appendFeedback(RoutineFeedback(routineID: reservation.routineID, occurrence: reservation.occurrence,
                                                  action: .accepted, suggestedTime: reservation.suggestedTime,
                                                  appliedTime: task.startDate ?? reservation.appliedTime,
                                                  todoID: task.id, recordedAt: now), to: &next)
            }
        }
        if next.pendingAcceptances != snapshot.pendingAcceptances { try persist(next) }
    }

    private func appendFeedback(_ entry: RoutineFeedback, to next: inout Snapshot) throws {
        guard let index = next.routines.firstIndex(where: { $0.id == entry.routineID && $0.isConfirmed }),
              entry.occurrence.timeIntervalSince1970.isFinite, entry.suggestedTime.timeIntervalSince1970.isFinite,
              entry.recordedAt.timeIntervalSince1970.isFinite,
              !next.feedback.contains(where: { $0.id == entry.id }) else { throw RoutineStoreError.invalidFeedback }
        var occurrenceCalendar = Calendar(identifier: .gregorian)
        occurrenceCalendar.timeZone = TimeZone(identifier: next.routines[index].timeZoneIdentifier) ?? .current
        guard occurrenceCalendar.startOfDay(for: entry.occurrence) == entry.occurrence else {
            throw RoutineStoreError.invalidFeedback
        }
        guard !next.feedback.contains(where: {
            $0.routineID == entry.routineID && $0.occurrence == entry.occurrence && ($0.action == .accepted || $0.action == .rejected)
        }), !next.pendingAcceptances.contains(where: { $0.routineID == entry.routineID && $0.occurrence == entry.occurrence }) else {
            throw RoutineStoreError.duplicateOccurrence
        }
        if entry.action != .rejected {
            guard let applied = entry.appliedTime, applied.timeIntervalSince1970.isFinite,
                  entry.action != .accepted || entry.todoID != nil,
                  entry.action != .postponed || (applied > entry.suggestedTime && applied >= entry.recordedAt) else {
                throw RoutineStoreError.invalidFeedback
            }
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(identifier: next.routines[index].timeZoneIdentifier) ?? .current
            next.routines[index].preferredHour = local.component(.hour, from: applied)
            next.routines[index].preferredMinute = local.component(.minute, from: applied)
            next.routines[index].hasManualOverrides = true
        }
        next.feedback.append(entry)
        next.routines[index].updatedAt = entry.recordedAt
        let recent = next.feedback.filter { $0.routineID == entry.routineID && $0.action != .postponed }
            .sorted { $0.recordedAt > $1.recordedAt }.prefix(3)
        if recent.count == 3 && recent.allSatisfy({ $0.action == .rejected }) {
            next.routines[index].isSuppressed = true
        }
    }

    private func hasMatchingTask(_ suggestion: RoutineSuggestion, routine: LearnedRoutine,
                                 postponedTime: Date?, todos: [Todo], calendar: Calendar) -> Bool {
        todos.contains { task in
            if task.sourceRef == suggestion.sourceRef { return true }
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
        routine.nextOccurrence.timeIntervalSince1970.isFinite && TimeZone(identifier: routine.timeZoneIdentifier) != nil
    }

    private func persist(_ next: Snapshot, allowUnreadableReplacement: Bool = false) throws {
        guard canReadStore || allowUnreadableReplacement else { throw RoutineStoreError.storeUnavailable }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writeData(encoder.encode(next), fileURL)
            snapshot = next
            canReadStore = true
            errorMessage = nil
            publish()
        } catch {
            errorMessage = RoutineStoreError.saveFailed.errorDescription
            throw RoutineStoreError.saveFailed
        }
    }

    private func publish() {
        routines = snapshot.routines
        feedback = snapshot.feedback
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
