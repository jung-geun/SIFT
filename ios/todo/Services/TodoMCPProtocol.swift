import Foundation

/// Minimal HTTP/1.1 request parsing and bearer auth for the loopback MCP endpoint.
nonisolated enum TodoMCPHTTP {
    static let maxHeaderBytes = 65_536
    static let maxBodyBytes = 1_048_576

    struct Request: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum ParseResult: Equatable {
        case incomplete
        case malformed
        case complete(Request)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .malformed : .incomplete
        }
        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rawLength = headers["content-length"] ?? "0"
        guard let length = Int(rawLength), length >= 0, length <= maxBodyBytes
        else { return .malformed }

        let bodyStart = range.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .complete(Request(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: body
        ))
    }

    /// Requires `Authorization: Bearer <token>`. Empty tokens never authorize.
    static func isAuthorized(_ headers: [String: String], token: String) -> Bool {
        guard !token.isEmpty, let value = headers["authorization"], value.hasPrefix("Bearer ") else {
            return false
        }
        return constantTimeEquals(String(value.dropFirst("Bearer ".count)), token)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
    static func serialize(status: Int, body: Data?) -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

/// Tool surface exposed to MCP clients. Implemented on the main actor against SwiftData.
@MainActor
protocol TodoMCPToolHost: AnyObject {
    func toolDefinitions() -> [[String: Any]]
    func call(name: String, arguments: [String: Any]) -> (text: String, isError: Bool)
}

/// JSON-RPC 2.0 dispatch for MCP (initialize, ping, tools/list, tools/call).
nonisolated enum TodoMCPRPC {
    static let protocolVersion = "2025-03-26"
    static let serverName = "SIFT"

    /// Returns nil for notifications (no `id`), which never receive a response body.
    @MainActor
    static func handle(_ body: Data, host: TodoMCPToolHost) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return encode(id: NSNull(), error: (-32700, "Parse error"))
        }
        guard let id = object["id"] else { return nil }
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": "1"]
            ])
        case "ping":
            return encode(id: id, result: [String: Any]())
        case "tools/list":
            return encode(id: id, result: ["tools": host.toolDefinitions()])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(id: id, error: (-32602, "Missing tool name"))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let outcome = host.call(name: name, arguments: arguments)
            return encode(id: id, result: [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError
            ])
        default:
            return encode(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private static func encode(id: Any, result: Any) -> Data? {
        serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(id: Any, error: (Int, String)) -> Data? {
        serialize(["jsonrpc": "2.0", "id": id, "error": ["code": error.0, "message": error.1]])
    }

    private static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
