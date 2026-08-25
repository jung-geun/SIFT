import Foundation
@testable import todo

final class ScriptedIMAPTransport: IMAPPreAuthCapabilityProbing, @unchecked Sendable {
    struct Route {
        let matching: String
        let outcome: Result<[String], Error>
        let isOnce: Bool
    }

    private let lock = NSLock()
    private var _commands: [String] = []
    private var routes: [Route] = []
    private var defaultResponses: [[String]] = []

    var commands: [String] {
        lock.withLock { _commands }
    }

    func reset() {
        lock.withLock {
            _commands.removeAll()
            routes.removeAll()
            defaultResponses.removeAll()
        }
    }

    func addRoute(matching substring: String, response: [String], once: Bool = false) {
        lock.withLock {
            routes.append(Route(matching: substring, outcome: .success(response), isOnce: once))
        }
    }

    func addRoute(matching substring: String, error: Error, once: Bool = false) {
        lock.withLock {
            routes.append(Route(matching: substring, outcome: .failure(error), isOnce: once))
        }
    }

    func addDefaultResponse(_ response: [String]) {
        lock.withLock {
            defaultResponses.append(response)
        }
    }

    func connect(username: String, password: String) async throws {
        _ = try await connectPreAuth()
        try await login(username: username, password: password)
    }

    func connectPreAuth() async throws -> [String] {
        let (matchedOutcome, fallbackResponse): (Result<[String], Error>?, [String]?) = lock.withLock {
            _commands.append("CONNECT_PREAUTH")
            if let index = routes.firstIndex(where: { "CONNECT_PREAUTH".contains($0.matching) || $0.matching == "GREETING" }) {
                let route = routes[index]
                if route.isOnce {
                    routes.remove(at: index)
                }
                return (route.outcome, nil)
            }
            if !defaultResponses.isEmpty {
                return (nil, defaultResponses.removeFirst())
            }
            return (nil, ["* OK [CAPABILITY IMAP4rev1 MOVE] Server Ready"])
        }

        await Task.yield()

        if let matchedOutcome {
            return try matchedOutcome.get()
        }
        return fallbackResponse ?? ["* OK [CAPABILITY IMAP4rev1 MOVE] Server Ready"]
    }

    func login(username: String, password: String) async throws {
        let (matchedOutcome, fallbackResponse): (Result<[String], Error>?, [String]?) = lock.withLock {
            _commands.append("LOGIN \(username)")
            if let index = routes.firstIndex(where: { $0.matching.hasPrefix("LOGIN") || $0.matching == username }) {
                let route = routes[index]
                if route.isOnce {
                    routes.remove(at: index)
                }
                return (route.outcome, nil)
            }
            return (nil, ["A0000 OK LOGIN completed"])
        }

        await Task.yield()

        let lines: [String]
        if let matchedOutcome {
            lines = try matchedOutcome.get()
        } else {
            lines = fallbackResponse ?? ["A0000 OK LOGIN completed"]
        }
        if GmailIMAPError.isPermanentCredentialRejection(in: lines) {
            throw GmailIMAPError.credentialRejected
        }
        guard lines.contains(where: { $0.contains(" OK") }) else {
            throw GmailIMAPError.invalidResponse
        }
    }

    func execute(_ command: String) async throws -> [String] {
        let (matchedOutcome, fallbackResponse): (Result<[String], Error>?, [String]?) = lock.withLock {
            _commands.append(command)
            if let index = routes.firstIndex(where: { command.contains($0.matching) }) {
                let route = routes[index]
                if route.isOnce {
                    routes.remove(at: index)
                }
                return (route.outcome, nil)
            }
            if !defaultResponses.isEmpty {
                return (nil, defaultResponses.removeFirst())
            }
            return (nil, ["A0000 OK"])
        }

        await Task.yield()

        if let matchedOutcome {
            return try matchedOutcome.get()
        }
        return fallbackResponse ?? ["A0000 OK"]
    }

    func close() async {
        lock.withLock {
            _commands.append("CLOSE")
        }
        await Task.yield()
    }
}
