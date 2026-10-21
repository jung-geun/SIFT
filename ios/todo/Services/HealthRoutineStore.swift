import Foundation
import Combine
import SwiftData

@MainActor
final class HealthRoutineStore: ObservableObject {
    static let shared = HealthRoutineStore()
    private static let consentKey = "pieroot.todo.health.autoCreateConsent"
    private static func connectionKey(_ category: HealthHistoryCategory) -> String { "pieroot.todo.health.connected.\(category.rawValue)" }

    @Published private(set) var candidates: [HealthRoutineCandidate] = []
    @Published private(set) var records: [HealthHistoryRecord] = []
    @Published private(set) var states: [HealthHistoryCategory: HealthCategoryState] = [:]
    @Published private(set) var autoCreateEnabled = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private nonisolated struct Snapshot: Codable {
        var version = 1
        var records: [HealthHistoryRecord] = []
        var candidates: [HealthRoutineCandidate] = []
        var states: [HealthHistoryCategory: HealthCategoryState] = [:]
        var autoCreateConsent = false
        // Write-ahead, nonclinical occurrence tombstones. Never prune during normal history erasure.
        var consumed: Set<String> = []
    }
    private var snapshot = Snapshot()
    private let reader: any HealthHistoryReading
    private let fileURL: URL
    private let defaults: UserDefaults
    private let writer: (Data, URL) throws -> Void
    private let saveTasks: (ModelContext) throws -> Void
    private let clock: () -> Date
    private var blocked = false
    private var epoch: UInt64 = 0
    private var runningTask: Task<Void, Never>?

    /// Writers must atomically replace the file or throw before replacement. No unprotected fallback.
    init(reader: (any HealthHistoryReading)? = nil, fileURL: URL? = nil,
         defaults: UserDefaults = .standard, writer: ((Data, URL) throws -> Void)? = nil,
         saveTasks: ((ModelContext) throws -> Void)? = nil, clock: @escaping () -> Date = Date.init) {
        self.reader = reader ?? HealthHistoryReader()
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalHealthHistory", isDirectory: true).appendingPathComponent("history.json")
        self.defaults = defaults
        self.writer = writer ?? Self.writeProtected
        self.saveTasks = saveTasks ?? { try $0.save() }
        self.clock = clock
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let loaded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: self.fileURL))
                guard loaded.version == 1, loaded.candidates.allSatisfy(Self.valid),
                      Set(loaded.candidates.map(\.id)).count == loaded.candidates.count,
                      loaded.records.allSatisfy({ $0.startDate.timeIntervalSince1970.isFinite && !$0.id.isEmpty }),
                      loaded.consumed.allSatisfy({ $0.hasPrefix("health:") }) else { throw HealthHistoryError.storage }
                snapshot = loaded
            }
            // Independent local consent gates make disconnect and save failures fail closed across restarts.
            for category in HealthHistoryCategory.allCases where !defaults.bool(forKey: Self.connectionKey(category)) {
                snapshot.states[category, default: HealthCategoryState()].isConnected = false
            }
            if !defaults.bool(forKey: Self.consentKey) { snapshot.autoCreateConsent = false }
            publish()
        } catch { failClosed() }
    }

    func unavailableReason(for category: HealthHistoryCategory) -> String? { reader.unavailableReason(for: category) }

    /// Retain local erase/reset access even if HealthKit becomes unavailable.
    var hasLocalData: Bool {
        blocked || !snapshot.records.isEmpty || !snapshot.candidates.isEmpty
            || !snapshot.consumed.isEmpty || snapshot.autoCreateConsent
            || snapshot.states.values.contains(where: { $0.isConnected })
    }

    func connect(_ category: HealthHistoryCategory, context: ModelContext,
                 now: Date = Date(), calendar: Calendar = .current) async {
        guard !blocked else { return }
        cancelRefresh()
        let token = epoch
        isRefreshing = true
        let startedAt = clock()
        defer { if token == epoch { isRefreshing = false } }
        do {
            if let reason = unavailableReason(for: category) { throw HealthHistoryError.unavailable(reason) }
            try await reader.requestRead(for: category)
            try Task.checkCancellation()
            guard token == epoch else { return }
            var next = snapshot
            next.states[category, default: HealthCategoryState()].isConnected = true
            try persist(next)
            defaults.set(true, forKey: Self.connectionKey(category))
            publish()
            // Querying, rather than the prompt's completion, supplies evidence. Empty is ambiguous.
            let queryDate = now.addingTimeInterval(max(0, clock().timeIntervalSince(startedAt)))
            await refresh(context: context, now: queryDate, calendar: calendar)
        } catch is CancellationError { }
        catch { if token == epoch && !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    /// Disconnect does not revoke OS permission. It immediately cancels queries and erases this category.
    func disconnect(_ category: HealthHistoryCategory) {
        defaults.set(false, forKey: Self.connectionKey(category))
        cancelRefresh()
        var next = snapshot
        next.states[category] = HealthCategoryState()
        next.records.removeAll { $0.category == category }
        next.candidates.removeAll { $0.category == category }
        do { try persist(next) } catch { /* persist already blocks all generation */ }
    }

    func setAutoCreateEnabled(_ enabled: Bool) throws {
        cancelRefresh()
        if !enabled { defaults.set(false, forKey: Self.consentKey) }
        var next = snapshot
        next.autoCreateConsent = enabled
        try persist(next)
        defaults.set(enabled, forKey: Self.consentKey)
        publish()
    }

    func approveSource(_ id: String, category: HealthHistoryCategory, approved: Bool,
                       now: Date = Date(), calendar: Calendar = .current) throws {
        cancelRefresh()
        guard snapshot.states[category]?.isConnected == true,
              snapshot.records.contains(where: { $0.category == category && $0.sourceID == id }) else {
            throw HealthHistoryError.invalidSchedule
        }
        var next = snapshot
        if approved { next.states[category, default: HealthCategoryState()].approvedSourceIDs.insert(id) }
        else { next.states[category, default: HealthCategoryState()].approvedSourceIDs.remove(id) }
        // Changing source approval never silently confirms a newly learned schedule.
        rebuildCandidates(&next, now: now, calendar: calendar)
        try persist(next)
    }

    func confirm(_ draft: HealthRoutineCandidate) throws {
        cancelRefresh()
        guard let index = snapshot.candidates.firstIndex(where: { $0.id == draft.id }), Self.valid(draft),
              snapshot.candidates[index].category == draft.category,
              snapshot.candidates[index].sourceID == draft.sourceID,
              snapshot.states[draft.category]?.isConnected == true,
              snapshot.states[draft.category]?.approvedSourceIDs.contains(draft.sourceID) == true else {
            throw HealthHistoryError.invalidSchedule
        }
        var next = snapshot
        // Only schedule and title are editable, never source identity or learned evidence.
        next.candidates[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        next.candidates[index].periodDays = draft.periodDays
        next.candidates[index].hour = draft.hour
        next.candidates[index].minute = draft.minute
        next.candidates[index].anchorDate = draft.anchorDate
        next.candidates[index].timeZoneIdentifier = draft.timeZoneIdentifier
        next.candidates[index].isConfirmed = true
        next.candidates[index].isEnabled = true
        try persist(next)
    }

    func setRoutineEnabled(_ id: String, enabled: Bool) throws {
        cancelRefresh()
        guard let index = snapshot.candidates.firstIndex(where: { $0.id == id }),
              snapshot.candidates[index].isConfirmed else { throw HealthHistoryError.invalidSchedule }
        var next = snapshot
        next.candidates[index].isEnabled = enabled
        try persist(next)
    }

    func cancelRefresh() {
        epoch &+= 1
        runningTask?.cancel()
        runningTask = nil
        isRefreshing = false
    }

    /// Does not request permission. Foreground refresh is inert until the user connects a category.
    func refresh(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) async {
        guard !blocked, snapshot.states.values.contains(where: { $0.isConnected }) else { return }
        cancelRefresh()
        let token = epoch
        isRefreshing = true
        let task = Task { await performRefresh(context: context, now: now, calendar: calendar, token: token) }
        runningTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func performRefresh(context: ModelContext, now: Date, calendar: Calendar, token: UInt64) async {
        defer { if token == epoch { isRefreshing = false; runningTask = nil } }
        let startedAt = clock()
        do {
            var next = snapshot
            next.records = []
            let from = calendar.date(byAdding: .day, value: -HealthRoutineLearning.historyDays, to: now) ?? now
            for category in HealthHistoryCategory.allCases where next.states[category]?.isConnected == true {
                if let reason = unavailableReason(for: category) { throw HealthHistoryError.unavailable(reason) }
                let fetched = try await reader.history(for: category, from: from, through: now)
                try Task.checkCancellation()
                guard token == epoch else { return }
                var bounded = fetched.filter { $0.category == category && $0.startDate >= from && $0.startDate <= now }
                if category == .medication {
                    // NSSecureCoding preserves the opaque concept, not a guaranteed canonical byte
                    // representation. Stable sample UUID overlap pins each group to its previous key.
                    // With no overlap, a changed encoding yields an unconfirmed candidate, never an
                    // automatic replacement of the user's confirmed medication schedule.
                    let previous = Dictionary(snapshot.records.filter { $0.category == category }
                        .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    var oldKeys: [String: String] = [:]
                    for record in bounded {
                        if let old = previous[record.id], old.sourceID == record.sourceID {
                            oldKeys[record.sourceID + "\u{0}" + record.kindKey] = old.kindKey
                        }
                    }
                    bounded = bounded.map { record in
                        var record = record
                        record.kindKey = oldKeys[record.sourceID + "\u{0}" + record.kindKey] ?? record.kindKey
                        return record
                    }
                }
                next.records.append(contentsOf: bounded)
                next.states[category, default: HealthCategoryState()].lastRead = now
                next.states[category, default: HealthCategoryState()].readRecordCount = bounded.count
            }
            rebuildCandidates(&next, now: now, calendar: calendar)
            try Task.checkCancellation()
            guard token == epoch else { return }
            try persist(next)
            // Same actor, no suspension between the cancellation/consent check and the task transaction.
            let generationDate = now.addingTimeInterval(max(0, clock().timeIntervalSince(startedAt)))
            try generate(context: context, now: generationDate)
        } catch is CancellationError { }
        catch { if token == epoch && !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    private func rebuildCandidates(_ next: inout Snapshot, now: Date, calendar: Calendar) {
        let old = Dictionary(uniqueKeysWithValues: next.candidates.map { ($0.id, $0) })
        next.candidates = HealthHistoryCategory.allCases.flatMap { category -> [HealthRoutineCandidate] in
            guard next.states[category]?.isConnected == true else { return [] }
            return HealthRoutineLearning.learn(records: next.records.filter { $0.category == category },
                approvedSources: next.states[category]?.approvedSourceIDs ?? [], now: now, calendar: calendar)
        }.map { learned in
            guard let saved = old[learned.id], saved.isConfirmed else { return learned }
            var result = learned
            result.title = saved.title
            result.periodDays = saved.periodDays
            result.hour = saved.hour
            result.minute = saved.minute
            result.anchorDate = saved.anchorDate
            result.timeZoneIdentifier = saved.timeZoneIdentifier
            result.isConfirmed = true
            result.isEnabled = saved.isEnabled
            return result
        }.sorted { $0.id < $1.id }
    }

    /// Durable reservation precedes SwiftData insertion. Completion/deletion/restarts cannot recreate it.
    /// If the task save fails the reservation stays consumed; safety wins over automatic retry.
    @discardableResult
    func generate(context: ModelContext, now: Date = Date()) throws -> Int {
        guard autoCreateEnabled, !blocked, errorMessage == nil, !Task.isCancelled else { return 0 }
        // Do not commit or roll back an unrelated editor's unsaved work.
        guard !context.hasChanges else { return 0 }
        let startedAt = clock()
        let existing = try context.fetch(FetchDescriptor<Todo>())
        let existingRefs = Set(existing.lazy.map(\.sourceRef))
        var reserved = snapshot
        reserved.consumed.formUnion(existingRefs.lazy.filter { $0.hasPrefix("health:") })
        var proposals: [(HealthRoutineCandidate, Date, String)] = []
        for candidate in snapshot.candidates where candidate.isConfirmed && candidate.isEnabled {
            guard snapshot.states[candidate.category]?.isConnected == true,
                  snapshot.states[candidate.category]?.approvedSourceIDs.contains(candidate.sourceID) == true,
                  unavailableReason(for: candidate.category) == nil,
                  candidate.evidenceEnd >= now.addingTimeInterval(-90 * 86400),
                  let occurrence = HealthRoutineLearning.nextOccurrence(candidate, now: now) else { continue }
            let ref = HealthRoutineLearning.sourceRef(candidate, occurrence: occurrence)
            guard !reserved.consumed.contains(ref) else { continue }
            proposals.append((candidate, occurrence, ref))
        }
        guard !proposals.isEmpty || reserved.consumed != snapshot.consumed else { return 0 }
        reserved.consumed.formUnion(proposals.lazy.map { $0.2 })
        try persist(reserved)
        try Task.checkCancellation()
        guard !proposals.isEmpty else { return 0 }
        var insertedCount = 0
        for (candidate, occurrence, ref) in proposals {
            let insertionDate = now.addingTimeInterval(max(0, clock().timeIntervalSince(startedAt)))
            guard occurrence > insertionDate else { continue }
            let task = Todo(title: candidate.title, startDate: occurrence, dueDate: occurrence,
                            source: .manual, sourceRef: ref, reminderOffsets: [])
            // No recorder, HealthKit write, calendar registration, AI request or notification.
            context.insert(task)
            insertedCount += 1
        }
        guard insertedCount > 0 else { return 0 }
        do { try saveTasks(context) }
        catch {
            context.rollback()
            errorMessage = HealthCopy.text("health.error.taskSave", "Task saving failed. Reserved occurrences will not be automatically retried, to avoid duplicates.", "할 일 저장에 실패했습니다. 중복 방지를 위해 예약된 발생분은 자동 재시도하지 않습니다.")
            throw error
        }
        return insertedCount
    }

    /// Privacy erasure preserves opaque deduplication tombstones, not history or schedule evidence.
    func eraseHistory() throws { try erase(keepTombstones: true) }
    /// Explicit destructive reset also forgets tombstones. Existing main tasks are not deleted.
    func resetAll() throws { try erase(keepTombstones: false) }
    private func erase(keepTombstones: Bool) throws {
        cancelRefresh()
        defaults.set(false, forKey: Self.consentKey)
        for category in HealthHistoryCategory.allCases { defaults.set(false, forKey: Self.connectionKey(category)) }
        var empty = Snapshot()
        if keepTombstones { empty.consumed = snapshot.consumed }
        try persist(empty, allowReset: true)
    }

    private static func valid(_ candidate: HealthRoutineCandidate) -> Bool {
        !candidate.id.isEmpty && !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !candidate.sourceID.isEmpty && !candidate.kindKey.isEmpty &&
        candidate.distinctDays >= HealthRoutineLearning.minimumDistinctDays && candidate.recordCount >= candidate.distinctDays &&
        candidate.regularity.isFinite && (HealthRoutineLearning.minimumRegularity...1).contains(candidate.regularity) &&
        candidate.evidenceStart <= candidate.evidenceEnd && (1...90).contains(candidate.periodDays) &&
        (0...23).contains(candidate.hour) && (0...59).contains(candidate.minute) &&
        candidate.anchorDate.timeIntervalSince1970.isFinite && TimeZone(identifier: candidate.timeZoneIdentifier) != nil
    }

    private func persist(_ next: Snapshot, allowReset: Bool = false) throws {
        guard !blocked || allowReset else { throw HealthHistoryError.storage }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writer(encoder.encode(next), fileURL)
            snapshot = next
            blocked = false
            errorMessage = nil
            publish()
        } catch { failClosed(); throw HealthHistoryError.storage }
    }

    private func failClosed() {
        blocked = true
        defaults.set(false, forKey: Self.consentKey)
        for category in HealthHistoryCategory.allCases { defaults.set(false, forKey: Self.connectionKey(category)) }
        errorMessage = HealthHistoryError.storage.localizedDescription
        publish()
    }

    private func publish() {
        candidates = snapshot.candidates
        records = snapshot.records
        states = snapshot.states
        for category in HealthHistoryCategory.allCases {
            if blocked || !defaults.bool(forKey: Self.connectionKey(category)) {
                states[category, default: HealthCategoryState()].isConnected = false
            }
        }
        autoCreateEnabled = !blocked && snapshot.autoCreateConsent && defaults.bool(forKey: Self.consentKey)
    }

    private static func writeProtected(_ data: Data, to fileURL: URL) throws {
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
