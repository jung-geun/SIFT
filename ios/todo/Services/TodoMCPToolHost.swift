import Foundation
import SwiftData

/// Todo tools for MCP clients. Reads and writes the same main store as the app UI.
@MainActor
final class TodoMCPToolsHost: TodoMCPToolHost {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    private enum ToolError: Error {
        case invalid(String)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func toolDefinitions() -> [[String: Any]] {
        let idSchema: [String: Any] = ["type": "string", "description": "Todo UUID from list_todos or add_todo."]
        let tagsSchema: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let dueSchema: [String: Any] = ["type": "string", "description": "ISO 8601 date-time, e.g. 2026-11-20T09:00:00Z."]
        return [
            [
                "name": "list_todos",
                "description": "List to-dos. status: active (default), completed, or all. Optional exact tag filter.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["active", "completed", "all"]],
                        "tag": ["type": "string"]
                    ]
                ]
            ],
            [
                "name": "add_todo",
                "description": "Create a manual to-do.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "notes": ["type": "string"],
                        "tags": tagsSchema,
                        "dueDate": dueSchema
                    ],
                    "required": ["title"]
                ]
            ],
            [
                "name": "update_todo",
                "description": "Change a to-do's title, notes, or tags. Omitted fields are unchanged.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "title": ["type": "string"],
                        "notes": ["type": "string"],
                        "tags": tagsSchema
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "complete_todo",
                "description": "Mark a to-do completed (default) or reopen it with completed=false.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "completed": ["type": "boolean"]
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "list_tags",
                "description": "List every distinct tag used by to-dos.",
                "inputSchema": ["type": "object", "properties": [String: Any]()]
            ]
        ]
    }

    func call(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        do {
            let result: Any
            switch name {
            case "list_todos": result = try listTodos(arguments)
            case "add_todo": result = try addTodo(arguments)
            case "update_todo": result = try updateTodo(arguments)
            case "complete_todo": result = try completeTodo(arguments)
            case "list_tags": result = try listTags()
            default: throw ToolError.invalid("Unknown tool: \(name)")
            }
            return (Self.json(result), false)
        } catch ToolError.invalid(let message) {
            return (message, true)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: - Tools

    private func listTodos(_ arguments: [String: Any]) throws -> [[String: Any]] {
        let status = (arguments["status"] as? String) ?? "active"
        guard ["active", "completed", "all"].contains(status) else {
            throw ToolError.invalid("status must be active, completed, or all")
        }
        let tag = arguments["tag"] as? String
        let todos = try context().fetch(FetchDescriptor<Todo>())
            .filter { todo in
                switch status {
                case "completed": todo.isCompleted
                case "all": true
                default: !todo.isCompleted && todo.triage == .todo
                }
            }
            .filter { tag == nil || $0.tags.contains(tag!) }
            .sorted { $0.createdAt < $1.createdAt }
        return todos.map(Self.summary)
    }

    private func addTodo(_ arguments: [String: Any]) throws -> [String: Any] {
        let title = try requiredTitle(arguments["title"])
        let context = context()
        let todo = Todo(
            title: title,
            notes: (arguments["notes"] as? String) ?? "",
            dueDate: try parseDate(arguments["dueDate"]),
            source: .manual,
            tags: try parseTags(arguments["tags"]) ?? []
        )
        context.insert(todo)
        TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: context)
        try context.save()
        return Self.summary(todo)
    }

    private func updateTodo(_ arguments: [String: Any]) throws -> [String: Any] {
        let context = context()
        let todo = try find(arguments, in: context)
        if arguments["title"] != nil { todo.title = try requiredTitle(arguments["title"]) }
        if let notes = arguments["notes"] as? String { todo.notes = notes }
        if let tags = try parseTags(arguments["tags"]) { todo.tags = tags }
        todo.updatedAt = Date()
        try context.save()
        return Self.summary(todo)
    }

    private func completeTodo(_ arguments: [String: Any]) throws -> [String: Any] {
        let context = context()
        let todo = try find(arguments, in: context)
        let completed = (arguments["completed"] as? Bool) ?? true
        TodoMutations.setCompleted(todo, completed: completed, in: context)
        try context.save()
        return Self.summary(todo)
    }

    private func listTags() throws -> [String] {
        let tags = try context().fetch(FetchDescriptor<Todo>()).flatMap(\.tags).filter { !$0.isEmpty }
        return Array(Set(tags)).sorted()
    }

    // MARK: - Helpers

    /// The UI's main context: MCP reads see unsaved UI edits and writes share one row owner.
    private func context() -> ModelContext {
        container.mainContext
    }

    private func find(_ arguments: [String: Any], in context: ModelContext) throws -> Todo {
        guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) else {
            throw ToolError.invalid("id must be a todo UUID")
        }
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        guard let todo = try context.fetch(descriptor).first else {
            throw ToolError.invalid("Todo not found: \(raw)")
        }
        return todo
    }

    private func requiredTitle(_ value: Any?) throws -> String {
        let title = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw ToolError.invalid("title must be a non-empty string") }
        return title
    }

    /// nil when the field is absent; otherwise trimmed, non-empty, de-duplicated tags.
    private func parseTags(_ value: Any?) throws -> [String]? {
        guard let value else { return nil }
        guard let raw = value as? [String] else { throw ToolError.invalid("tags must be an array of strings") }
        var seen = Set<String>()
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func parseDate(_ value: Any?) throws -> Date? {
        guard let value else { return nil }
        guard let text = value as? String, let date = Self.isoFormatter.date(from: text) else {
            throw ToolError.invalid("dueDate must be an ISO 8601 date-time")
        }
        return date
    }

    private static func summary(_ todo: Todo) -> [String: Any] {
        [
            "id": todo.id.uuidString,
            "title": todo.title,
            "notes": todo.notes,
            "tags": todo.tags,
            "isCompleted": todo.isCompleted,
            "dueDate": todo.dueDate.map { isoFormatter.string(from: $0) } ?? NSNull()
        ]
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }
}
