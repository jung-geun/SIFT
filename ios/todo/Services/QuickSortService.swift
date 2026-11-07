import Combine
import CryptoKit
import Foundation
import SwiftData

/// Weak priority scoring belongs to a successful, local creation transaction, not
/// to a change in the visible Todo collection. Restores and status changes never
/// enter this queue. The device-local receipt contains identity and a digest only.
@MainActor
final class QuickSortService {
    static let shared = QuickSortService()
    static let defaultMaxConcurrency = 2
    struct Receipt: Codable, Equatable {
        let id: UUID
        let createdAt: Date
        let digest: String
    }

    private final class Insertion {
        weak var todo: Todo?
        let createdAt: Date

        init(_ todo: Todo) {
            self.todo = todo
            createdAt = todo.createdAt
        }
    }

    private struct StagedInsertions {
        var order: [UUID] = []
        var items: [UUID: Insertion] = [:]

        mutating func record(_ id: UUID, _ insertion: Insertion) {
            if items[id] == nil { order.append(id) }
            items[id] = insertion
        }
    }

    private let defaults: UserDefaults
    private let maxConcurrency: Int
    private let engine: @MainActor () -> any IntelligenceService
    private var context: ModelContext?
    private var saveSubscription: AnyCancellable?
    private var staged: [ObjectIdentifier: StagedInsertions] = [:]
    private var receipts: [UUID: Receipt] = [:]
    private var receiptOrder: [UUID] = []
    private var queue: [UUID] = []
    private var queuedIDs: Set<UUID> = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var storageKey = ""
    private var generation = UUID()

    init(defaults: UserDefaults = .standard,
         maxConcurrency: Int = QuickSortService.defaultMaxConcurrency,
         engine: @escaping @MainActor () -> any IntelligenceService = { RoutedIntelligenceEngine() }) {
        self.defaults = defaults
        self.maxConcurrency = max(1, maxConcurrency)
        self.engine = engine
    }

    /// Start once the local app store is ready, irrespective of iCloud opt-in.
    /// Reopening a store resumes only its own locally committed creation receipts.
    func start(context: ModelContext) {
        guard self.context !== context else { return }
        stop()
        self.context = context
        let urls = context.container.configurations.map { $0.url.absoluteString }.sorted()
        let storeDigest = SHA256.hash(data: Data(urls.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        storageKey = "sift.local.newTaskPriority.\(storeDigest)"
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Receipt].self, from: data) {
            for receipt in saved { setReceipt(receipt) }
        }
        saveSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .sink { [weak self] notification in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.didSave(notification) }
                } else {
                    Task { @MainActor [weak self] in self?.didSave(notification) }
                }
            }
        for id in receiptOrder { enqueue(id) }
    }

    func stop() {
        generation = UUID()
        queue.removeAll()
        queuedIDs.removeAll()
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        saveSubscription = nil
        staged.removeAll()
        receipts.removeAll()
        receiptOrder.removeAll()
        context = nil
    }

    /// Called only alongside the actual insertion, before its transaction saves.
    /// Re-recording creation for a previously persisted row is not a new task.
    func recordInsertion(_ todo: Todo, in insertionContext: ModelContext) {
        guard let context, context.container === insertionContext.container,
              Self.isEligible(todo),
              insertionContext.insertedModelsArray.contains(where: { ($0 as? Todo) === todo }) else { return }
        let id = todo.id
        let committed = ModelContext(context.container)
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        guard let existing = try? committed.fetch(descriptor), existing.isEmpty,
              let digest = Self.digest(todo) else { return }
        // Journal intent before the creation transaction. A restart may recover
        // it only when that exact input actually exists in the committed store.
        // No provider runs from this pre-save hook.
        setReceipt(Receipt(id: id, createdAt: todo.createdAt, digest: digest))
        persist(synchronously: true)
        staged[ObjectIdentifier(insertionContext), default: StagedInsertions()].record(id, Insertion(todo))
    }

    private func didSave(_ notification: Notification) {
        guard let savedContext = notification.object as? ModelContext,
              let context, savedContext.container === context.container,
              let insertions = staged.removeValue(forKey: ObjectIdentifier(savedContext)) else { return }
        // A fresh context proves the insertion reached the persistent store. In
        // particular, an unrelated save cannot bless a rolled-back insertion.
        let committed = ModelContext(context.container)
        for id in insertions.order {
            guard let insertion = insertions.items[id],
                  let original = insertion.todo, original.modelContext === savedContext,
                  let todo = Self.fetch(id, in: committed), todo.createdAt == insertion.createdAt,
                  Self.isEligible(todo), let digest = Self.digest(todo) else {
                removeReceipt(id)
                continue
            }
            setReceipt(Receipt(id: id, createdAt: todo.createdAt, digest: digest))
        }
        persist()
        for id in insertions.order { enqueue(id) }
    }

    private func persist(synchronously: Bool = false) {
        let ordered = receiptOrder.compactMap { receipts[$0] }
        guard !storageKey.isEmpty, let data = try? JSONEncoder().encode(ordered) else { return }
        defaults.set(data, forKey: storageKey)
        if synchronously {
            // Unlike ordinary preferences, this journal must precede the store
            // commit even when the process terminates before didSave delivery.
            defaults.synchronize()
        }
    }

    private func setReceipt(_ receipt: Receipt) {
        if receipts[receipt.id] == nil { receiptOrder.append(receipt.id) }
        receipts[receipt.id] = receipt
    }

    private func removeReceipt(_ id: UUID) {
        guard receipts.removeValue(forKey: id) != nil else { return }
        receiptOrder.removeAll { $0 == id }
    }

    private func enqueue(_ id: UUID) {
        guard receipts[id] != nil, workers[id] == nil, !queuedIDs.contains(id) else { return }
        queue.append(id)
        queuedIDs.insert(id)
        drainQueue()
    }

    private func drainQueue() {
        guard context != nil else { return }
        while workers.count < maxConcurrency, !queue.isEmpty {
            let id = queue.removeFirst()
            queuedIDs.remove(id)
            guard receipts[id] != nil, workers[id] == nil else { continue }
            let generation = generation
            workers[id] = Task { @MainActor [weak self] in
                defer {
                    if let self, self.generation == generation {
                        self.workers[id] = nil
                        self.drainQueue()
                    }
                }
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                await self.analyze(id, generation: generation)
            }
        }
    }

    private func finish(_ id: UUID) {
        removeReceipt(id)
        if queuedIDs.remove(id) != nil { queue.removeAll { $0 == id } }
        persist()
    }

    private func analyze(_ id: UUID, generation: UUID) async {
        guard let context, let receipt = receipts[id],
              let visibleTodo = Self.fetch(id, in: context), Self.matches(visibleTodo, receipt) else {
            finish(id)
            return
        }
        let workContext = ModelContext(context.container)
        workContext.autosaveEnabled = false
        guard let todo = Self.fetch(id, in: workContext), Self.matches(todo, receipt) else {
            finish(id)
            return
        }
        let persona = Self.persona(in: context)
        // Independent per-ID work: a slow provider for one task never queues
        // unrelated task creation or any source synchronization behind it.
        let results: [PriorityResult]
        do {
            results = try await engine().prioritize(todos: [todo], events: [], persona: persona)
        } catch {
            guard !Task.isCancelled, self.generation == generation,
                  let current = Self.fetch(id, in: context), Self.matches(current, receipt) else { return }
            let fallback = (try? await HeuristicEngine().prioritize(todos: [todo], events: [], persona: persona)) ?? []
            results = fallback.map {
                var result = $0
                result.executionPath = .rules(.providerExecutionFailed)
                result.fallbackReason = RuleFallbackReason.providerExecutionFailed.rawValue
                return result
            }
        }
        guard !Task.isCancelled, self.generation == generation else { return }
        // User edits, explicit AI sorting, review/completion transitions and
        // replacement rows invalidate the original input, including after restart.
        guard let liveTodo = Self.fetch(id, in: context), Self.matches(liveTodo, receipt),
              Self.samePersona(persona, Self.persona(in: context)),
              let result = results.first(where: { $0.todoID == id }) else {
            finish(id)
            return
        }
        // A fresh, isolated writer compares committed input as well as the UI's
        // current input. Saving this result must never commit unrelated edits
        // that accumulated in the UI context while the provider was suspended.
        let commitContext = ModelContext(context.container)
        commitContext.autosaveEnabled = false
        guard let committedTodo = Self.fetch(id, in: commitContext), Self.matches(committedTodo, receipt) else {
            finish(id)
            return
        }
        let oldScore = committedTodo.computedPriorityScore
        committedTodo.apply(result)
        TaskBehaviorRecorder.recordComputedPriorityChange(
            of: committedTodo, from: oldScore, to: committedTodo.computedPriorityScore,
            actor: result.engine == .heuristic ? .system : .artificialIntelligence, in: commitContext
        )
        do {
            try commitContext.save()
            // Publish only these already-committed fields for SwiftUI observers.
            // Never save or roll back the shared context here.
            liveTodo.apply(result)
            finish(id)
        } catch {
            commitContext.rollback()
        }
    }

    private static func isEligible(_ todo: Todo) -> Bool {
        todo.isEligibleForAutomaticPriority && !todo.isHealthRelated
    }

    private static func fetch(_ id: UUID, in context: ModelContext) -> Todo? {
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        // Ambiguous restored duplicates are never guessed at.
        guard let rows = try? context.fetch(descriptor), rows.count == 1 else { return nil }
        return rows[0]
    }

    private static func matches(_ todo: Todo, _ receipt: Receipt) -> Bool {
        isEligible(todo) && todo.createdAt == receipt.createdAt && digest(todo) == receipt.digest
    }

    private static func persona(in context: ModelContext) -> PersonaContext {
        var descriptor = FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let persona = try? context.fetch(descriptor).first else { return .empty }
        return PersonaContext(types: persona.personaTypes, description: persona.descriptionText)
    }

    private static func samePersona(_ lhs: PersonaContext, _ rhs: PersonaContext) -> Bool {
        lhs.types == rhs.types && lhs.description == rhs.description
    }

    private static func digest(_ todo: Todo) -> String? {
        func date(_ value: Date?) -> String { value.map { String($0.timeIntervalSinceReferenceDate) } ?? "nil" }
        let fields = [
            todo.id.uuidString, date(todo.createdAt), todo.title, todo.notes,
            date(todo.startDate), date(todo.dueDate), String(todo.isCompleted), date(todo.completedAt),
            todo.manualPriority.map(String.init) ?? "nil", String(todo.computedPriorityScore),
            todo.priorityReason, todo.aiEngine, todo.aiDetail, String(todo.aiNeedsNotification),
            date(todo.aiRecommendedTime), String(todo.aiPersonaFit), todo.aiRequestedProvider, todo.aiFallbackReason,
            todo.source, todo.sourceThreadID, todo.triageStatus,
            String(todo.hasLocalOnlySourceContent),
            String(todo.calendarOrigin == .siftMeeting || todo.calendarOrigin == .siftEmail),
            String(todo.isFixedSchedule), String(todo.estimatedDurationMinutes)
        ]
        guard let data = try? JSONEncoder().encode([fields, todo.tags]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}
