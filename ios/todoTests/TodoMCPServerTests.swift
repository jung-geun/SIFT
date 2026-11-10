import Foundation
import SwiftData
import Testing
@testable import todo

/// Real loopback listener + real HTTP requests; the store is in-memory.
@Suite("MCP loopback server end to end", .serialized)
@MainActor
struct TodoMCPServerTests {
    @Test("Missing or wrong token gets 401; bearer token gets the tool list over HTTP")
    func endToEndAuthAndToolList() async throws {
        let config = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.appSchema, configurations: [config])
        let server = TodoMCPServer()
        server.start(container: container)
        defer { server.stop() }

        let deadline = Date().addingTimeInterval(10)
        while !server.isRunning, server.lastError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.isRunning, "listener did not start: \(server.lastError ?? "timeout")")

        let url = try #require(URL(string: TodoMCPServer.endpointURL))
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        func post(authorization: String?) async throws -> (Int, Data) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }

        let (missingStatus, _) = try await post(authorization: nil)
        #expect(missingStatus == 401)

        let (wrongStatus, _) = try await post(authorization: "Bearer not-the-token")
        #expect(wrongStatus == 401)

        let token = try TodoMCPToken.current()
        let (status, data) = try await post(authorization: "Bearer \(token)")
        #expect(status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String }.sorted() == [
            "add_todo", "complete_todo", "list_tags", "list_todos", "update_todo"
        ])
    }
}
