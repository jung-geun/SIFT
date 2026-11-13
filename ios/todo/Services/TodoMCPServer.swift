import Combine
import Foundation
@preconcurrency import Network
import Security
import SwiftData

/// Bearer token for the loopback MCP endpoint. Device-only: never synced through iCloud Keychain.
nonisolated enum TodoMCPToken {
    private static let service = "pieroot.todo.mcp"
    private static let account = "bearer"

    static func current() throws -> String {
        if let data = try KeychainStore.getDeviceOnly(service: service, account: account),
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        return try regenerate()
    }

    @discardableResult
    static func regenerate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainStoreError.security(errSecParam)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try KeychainStore.setDeviceOnly(service: service, account: account, data: Data(token.utf8))
        return token
    }
}

/// Loopback-only MCP endpoint at http://127.0.0.1:<port>/mcp. Never binds LAN interfaces.
@MainActor
final class TodoMCPServer: ObservableObject {
    static let shared = TodoMCPServer()
    static let port: UInt16 = 47831
    static var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var tools: TodoMCPToolsHost?
    private var token = ""
    private let queue = DispatchQueue(label: "pieroot.todo.mcp.server")

    /// Starts the listener, or restarts it so a regenerated token takes effect.
    func start(container: ModelContainer) {
        stop()
        do {
            token = try TodoMCPToken.current()
            tools = TodoMCPToolsHost(container: container)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.handleState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        tools = nil
        isRunning = false
    }

    /// Rotates the bearer token. A running listener restarts so the old token stops working.
    func regenerateToken(container: ModelContainer) throws {
        try TodoMCPToken.regenerate()
        if listener != nil { start(container: container) }
    }

    static func currentToken() -> String? {
        try? TodoMCPToken.current()
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch TodoMCPHTTP.parse(buffer) {
            case .complete(let request):
                Task { @MainActor [weak self] in
                    await self?.respond(to: request, on: connection)
                }
            case .malformed:
                Self.send(TodoMCPHTTP.serialize(status: 400, body: nil), on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self?.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: TodoMCPHTTP.Request, on connection: NWConnection) async {
        let response: Data
        if request.path != "/mcp" {
            response = TodoMCPHTTP.serialize(status: 404, body: nil)
        } else if request.method != "POST" {
            response = TodoMCPHTTP.serialize(status: 405, body: nil)
        } else if !TodoMCPHTTP.isAuthorized(request.headers, token: token) {
            response = TodoMCPHTTP.serialize(status: 401, body: nil)
        } else if let tools, let body = TodoMCPRPC.handle(request.body, host: tools) {
            response = TodoMCPHTTP.serialize(status: 200, body: body)
        } else {
            // Notifications have no JSON-RPC response.
            response = TodoMCPHTTP.serialize(status: 202, body: nil)
        }
        Self.send(response, on: connection)
    }

    private nonisolated static func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
