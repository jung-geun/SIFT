import Foundation

/// Account invalidation cancels native requests even while their stream is waiting for another event.
@MainActor final class OpenAIRequestRegistry {
    static let shared = OpenAIRequestRegistry()
    private struct Request {
        let generation: UUID
        let scope: OpenAIDataScope?
        let additionalScopes: [OpenAIDataScope]
        let cancel: @Sendable () -> Void
    }
    private var requests: [UUID: Request] = [:]

    func register(generation: UUID, scope: OpenAIDataScope?, additionalScopes: [OpenAIDataScope], cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        requests[id] = Request(generation: generation, scope: scope, additionalScopes: additionalScopes, cancel: cancel)
        return id
    }
    func remove(_ id: UUID) { requests.removeValue(forKey: id) }
    func cancel(generation: UUID) {
        for request in requests.values where request.generation == generation { request.cancel() }
    }
    func cancel(scope: OpenAIDataScope) {
        for request in requests.values where request.scope == scope || request.additionalScopes.contains(scope) { request.cancel() }
    }
}
