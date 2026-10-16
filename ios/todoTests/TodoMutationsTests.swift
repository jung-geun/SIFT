import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Todo deletion durability", .serialized)
@MainActor
struct TodoMutationsTests {
    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContainer(at directory: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            url: directory.appendingPathComponent("store.sqlite"),
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppDataContainer.appSchema, configurations: [configuration])
    }

    // Separate scopes release each writer before the next container reopens the disk store.
    private func seedStore(at directory: URL, review: Bool = false, email: Bool = false) throws -> UUID {
        let container = try makeContainer(at: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = Todo(
            title: "Durable deletion",
            source: email ? .email : .manual,
            sourceRef: email ? "deletion-test-\(UUID().uuidString)" : ""
        )
        todo.triageStatus = review ? TodoTriage.review.rawValue : TodoTriage.todo.rawValue
        context.insert(todo)
        try context.save()
        return todo.id
    }

    private func deletePersistedTodo(at directory: URL, id: UUID) throws {
        let container = try makeContainer(at: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = try #require(context.fetch(FetchDescriptor<Todo>()).first { $0.id == id })
        try TodoMutations.delete(todo, in: context)
        // Deliberately no caller save, background transition, wait, or autosave.
        #expect(!context.hasChanges)
    }

    @Test("Successful delete survives immediate disk reopen with both audit records", arguments: [false, true])
    func deletionPersistsWithoutAutosave(review: Bool) throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try seedStore(at: directory, review: review)
        try deletePersistedTodo(at: directory, id: id)

        let reopened = try makeContainer(at: directory)
        let context = ModelContext(reopened)
        context.autosaveEnabled = false
        #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        let audits = try context.fetch(FetchDescriptor<TaskAuditEvent>())
        #expect(audits.count == 1)
        #expect(audits.first?.todoID == id)
        #expect(audits.first?.triageType == (review ? TodoTriage.review.rawValue : TodoTriage.todo.rawValue))
        let behaviors = try context.fetch(FetchDescriptor<TaskBehaviorEvent>())
        #expect(behaviors.count == 1)
        #expect(behaviors.first?.todoID == id)
        #expect(behaviors.first?.eventType == .deleted)
        #expect(behaviors.first?.actor == .user)
    }

    @Test("Real read-only store save failure throws and restores deletion without audit or email learning")
    func failedDeletionIsNotSuccess() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try seedStore(at: directory, email: true)
        let container = try makeContainer(at: directory, allowsSave: false)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = try #require(context.fetch(FetchDescriptor<Todo>()).first { $0.id == id })
        let sourceRef = todo.sourceRef
        #expect(!EmailLearningStore.shared.isDismissed(sourceRef))

        #expect(throws: Error.self) {
            try TodoMutations.delete(todo, in: context)
        }

        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<Todo>()).map(\.id) == [id])
        #expect(try context.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
        #expect(!EmailLearningStore.shared.isDismissed(sourceRef))
        let reopened = try makeContainer(at: directory, allowsSave: false)
        let freshContext = ModelContext(reopened)
        freshContext.autosaveEnabled = false
        #expect(try freshContext.fetch(FetchDescriptor<Todo>()).map(\.id) == [id])
        #expect(try freshContext.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
        #expect(try freshContext.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }

    @Test("Failed pending-change checkpoint leaves unrelated edits intact and does not start deletion")
    func failedCheckpointPreservesPendingChanges() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try seedStore(at: directory)
        let container = try makeContainer(at: directory, allowsSave: false)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let todo = try #require(context.fetch(FetchDescriptor<Todo>()).first { $0.id == id })
        let unrelatedTodo = Todo(title: "Unrelated pending edit")
        context.insert(unrelatedTodo)

        #expect(throws: Error.self) {
            try TodoMutations.delete(todo, in: context)
        }

        #expect(context.hasChanges)
        let rows = try context.fetch(FetchDescriptor<Todo>())
        #expect(Set(rows.map(\.id)) == Set([id, unrelatedTodo.id]))
        #expect(try context.fetch(FetchDescriptor<TaskAuditEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskBehaviorEvent>()).isEmpty)
    }
}
