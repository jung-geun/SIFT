import Foundation

/// Bounds an await that may not honor cancellation (for example a CoreML predict
/// that never returns). Unlike `withTaskGroup`, the caller resumes at the deadline
/// even if the operation is still running; its late result is discarded.
nonisolated enum AsyncDeadline {
    struct Expired: Error, Equatable {}

    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    static func run<T: Sendable>(
        _ limit: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let gate = ResumeGate()
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                do { try await Task.sleep(for: limit) }
                catch { return }
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: Expired())
                }
            }
        }
    }
}

/// Set once an awaiting caller stops accepting progress from a detached operation.
nonisolated final class PassFlag: @unchecked Sendable {
    var value = false
}
