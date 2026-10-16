import Foundation
@preconcurrency import Network

/// One attempt, one IPv4 loopback socket, one callback. Never listens on LAN interfaces.
@MainActor final class OpenAILoopbackListener: OpenAILoopbackListening {
    private let queue = DispatchQueue(label: "pieroot.todo.openai.loopback")
    private var listener: NWListener?
    private var readiness: CheckedContinuation<URL, Error>?
    private var receiver: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var redirect: URL?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private var consumed = false
    private var stopped = false

    func start() async throws -> URL {
        guard listener == nil, !stopped else { throw OpenAIConnectionError.unavailable }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port,
                          let uri = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else {
                        self.fail(.unavailable); return
                    }
                    self.redirect = uri
                    let ready = self.readiness; self.readiness = nil
                    ready?.resume(returning: uri)
                case .failed: self.fail(.unavailable)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.fail(.cancelled)
        }
        return try await withCheckedThrowingContinuation { continuation in
            readiness = continuation
            listener.start(queue: queue)
        }
    }

    func callback() async throws -> URL {
        if let result { return try result.get() }
        guard !stopped, receiver == nil else { throw OpenAIConnectionError.cancelled }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        readiness?.resume(throwing: OpenAIConnectionError.cancelled); readiness = nil
        receiver?.resume(throwing: OpenAIConnectionError.cancelled); receiver = nil
        if result == nil { result = .failure(OpenAIConnectionError.cancelled) }
    }

    private func fail(_ error: OpenAIConnectionError) {
        result = .failure(error)
        readiness?.resume(throwing: error); readiness = nil
        receiver?.resume(throwing: error); receiver = nil
        stop()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, !consumed, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.close(id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 32768, error == nil else { self.close(id); return }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(bytes, connection: connection, id: id)
                } else if complete { self.close(id) }
                else { self.receive(connection, id: id, buffer: bytes) }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard !consumed, let redirect, let text = String(data: data, encoding: .utf8) else { close(id); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(redirect.port!)",
              request[1].hasPrefix("/auth/callback?"),
              let url = URL(string: "http://127.0.0.1:\(redirect.port!)\(request[1])") else {
            respond("400 Bad Request", body: "Invalid sign-in callback.", connection: connection) { [weak self] in self?.close(id) }
            return
        }
        consumed = true
        respond("200 OK", body: "Return to SIFT to complete ChatGPT sign-in.", connection: connection) { [weak self] in
            guard let self, !self.stopped else { return }
            self.result = .success(url)
            let receiver = self.receiver; self.receiver = nil
            receiver?.resume(returning: url)
            self.stop()
        }
    }

    private func respond(_ status: String, body: String, connection: NWConnection,
                         completion: @escaping @MainActor () -> Void) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            Task { @MainActor in completion() }
        })
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
