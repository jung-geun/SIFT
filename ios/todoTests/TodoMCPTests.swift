import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("MCP HTTP framing and bearer auth")
struct TodoMCPHTTPTests {
    @Test("Incomplete body waits for Content-Length bytes")
    func incompleteBodyWaits() {
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":"
        #expect(TodoMCPHTTP.parse(Data(head.utf8)) == .incomplete)
    }

    @Test("Complete request exposes method, path, lowercased headers, and body")
    func completeRequestParses() {
        let body = "{\"jsonrpc\":\"2.0\"}"
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = TodoMCPHTTP.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer abc")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
    }

    @Test("Non-numeric or oversized Content-Length is malformed")
    func badLengthIsMalformed() {
        let bad = "POST /mcp HTTP/1.1\r\nContent-Length: nope\r\n\r\n"
        #expect(TodoMCPHTTP.parse(Data(bad.utf8)) == .malformed)
        let huge = "POST /mcp HTTP/1.1\r\nContent-Length: \(TodoMCPHTTP.maxBodyBytes + 1)\r\n\r\n"
        #expect(TodoMCPHTTP.parse(Data(huge.utf8)) == .malformed)
    }

    @Test("Requests without the exact bearer token are rejected")
    func bearerTokenIsRequired() {
        #expect(!TodoMCPHTTP.isAuthorized([:], token: "secret"))
        #expect(!TodoMCPHTTP.isAuthorized(["authorization": "Bearer wrong"], token: "secret"))
        #expect(!TodoMCPHTTP.isAuthorized(["authorization": "Basic secret"], token: "secret"))
        #expect(!TodoMCPHTTP.isAuthorized(["authorization": "Bearer "], token: ""))
        #expect(TodoMCPHTTP.isAuthorized(["authorization": "Bearer secret"], token: "secret"))
    }

    @Test("A 401 response advertises the bearer scheme")
    func unauthorizedResponseChallenges() {
        let text = String(decoding: TodoMCPHTTP.serialize(status: 401, body: nil), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized"))
        #expect(text.contains("WWW-Authenticate: Bearer"))
    }
}

@Suite("MCP JSON-RPC dispatch")
@MainActor
struct TodoMCPRPCTests {
    private final class StubHost: TodoMCPToolHost {
        var lastCall: (name: String, arguments: [String: Any])?
        func toolDefinitions() -> [[String: Any]] { [["name": "list_tags"]] }
        func call(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
            lastCall = (name, arguments)
            return ("ok", false)
        }
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("initialize advertises the tools capability")
    func initializeAdvertisesTools() throws {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let response = try object(TodoMCPRPC.handle(request, host: StubHost()))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == TodoMCPRPC.protocolVersion)
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(response["id"] as? Int == 1)
    }

    @Test("Notifications produce no response body")
    func notificationHasNoResponse() {
        let request = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        #expect(TodoMCPRPC.handle(request, host: StubHost()) == nil)
    }

    @Test("Unknown methods return JSON-RPC method-not-found")
    func unknownMethodErrors() throws {
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#.utf8)
        let response = try object(TodoMCPRPC.handle(request, host: StubHost()))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test("tools/call forwards name and arguments to the host")
    func toolsCallForwardsArguments() throws {
        let host = StubHost()
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_todos","arguments":{"tag":"afterglow"}}}"#.utf8)
        _ = TodoMCPRPC.handle(request, host: host)
        #expect(host.lastCall?.name == "list_todos")
        #expect(host.lastCall?.arguments["tag"] as? String == "afterglow")
    }
}

@Suite("MCP todo tools against the app schema")
@MainActor
struct TodoMCPToolHostTests {
    private func makeHost() throws -> (TodoMCPToolsHost, ModelContainer) {
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
        return (TodoMCPToolsHost(container: container), container)
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    @Test("add_todo then list_todos filtered by exact tag")
    func addThenFilterByTag() throws {
        let (host, _) = try makeHost()
        let added = host.call(name: "add_todo", arguments: ["title": "  Ship dashboard ", "tags": ["afterglow", " afterglow ", ""]])
        #expect(!added.isError)

        _ = host.call(name: "add_todo", arguments: ["title": "Unrelated", "tags": ["other"]])

        let tagged = try #require(try json(host.call(name: "list_todos", arguments: ["tag": "afterglow"]).text) as? [[String: Any]])
        #expect(tagged.count == 1)
        #expect(tagged.first?["title"] as? String == "Ship dashboard")
        #expect(tagged.first?["tags"] as? [String] == ["afterglow"])
    }

    @Test("add_todo rejects an empty title and bad dueDate with isError")
    func addRejectsInvalidInput() {
        let (host, _) = try! makeHost()
        #expect(host.call(name: "add_todo", arguments: ["title": "   "]).isError)
        #expect(host.call(name: "add_todo", arguments: ["title": "x", "dueDate": "tomorrow"]).isError)
    }

    @Test("complete_todo marks completed and default list excludes it")
    func completeRemovesFromActive() throws {
        let (host, _) = try makeHost()
        let added = try json(host.call(name: "add_todo", arguments: ["title": "Finish memo"]).text) as? [String: Any]
        let id = try #require(added?["id"] as? String)

        let completed = host.call(name: "complete_todo", arguments: ["id": id])
        #expect(!completed.isError)

        let active = try #require(try json(host.call(name: "list_todos", arguments: [:]).text) as? [[String: Any]])
        #expect(active.isEmpty)
        let done = try #require(try json(host.call(name: "list_todos", arguments: ["status": "completed"]).text) as? [[String: Any]])
        #expect(done.map { $0["id"] as? String } == [id])
    }

    @Test("update_todo changes only supplied fields")
    func updateKeepsOmittedFields() throws {
        let (host, _) = try makeHost()
        let added = try json(host.call(name: "add_todo", arguments: ["title": "Draft", "notes": "keep me"]).text) as? [String: Any]
        let id = try #require(added?["id"] as? String)

        _ = host.call(name: "update_todo", arguments: ["id": id, "title": "Final"])
        let updated = try json(host.call(name: "list_todos", arguments: [:]).text) as? [[String: Any]]
        #expect(updated?.first?["title"] as? String == "Final")
        #expect(updated?.first?["notes"] as? String == "keep me")
    }

    @Test("Unknown id and unknown tool are errors, not silent success")
    func unknownTargetsAreErrors() {
        let (host, _) = try! makeHost()
        #expect(host.call(name: "complete_todo", arguments: ["id": UUID().uuidString]).isError)
        #expect(host.call(name: "delete_everything", arguments: [:]).isError)
    }

    @Test("list_tags returns distinct sorted tags")
    func listTagsDistinctSorted() throws {
        let (host, _) = try makeHost()
        _ = host.call(name: "add_todo", arguments: ["title": "A", "tags": ["zeta", "alpha"]])
        _ = host.call(name: "add_todo", arguments: ["title": "B", "tags": ["alpha"]])
        let tags = try #require(try json(host.call(name: "list_tags", arguments: [:]).text) as? [String])
        #expect(tags == ["alpha", "zeta"])
    }
}
