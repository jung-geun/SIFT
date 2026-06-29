import Foundation
import Testing
@testable import todo

actor AIProviderTestIsolation {
    static let shared = AIProviderTestIsolation()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}
