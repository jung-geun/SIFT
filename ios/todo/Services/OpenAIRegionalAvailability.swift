import Combine
import Foundation
import StoreKit
import os

/// Storefront policy is resolved afresh, never inferred from language or persisted.
/// Unknown storefronts stay closed; this does not change provider or sharing consent.
@MainActor
final class OpenAIRegionalAvailability: ObservableObject {
    nonisolated final class RequestSnapshot: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: false)

        nonisolated var allowsRequests: Bool { storage.withLock { $0 } }
        nonisolated func setAllowed(_ value: Bool) { storage.withLock { $0 = value } }
    }

    struct Sources {
        let current: @MainActor () async -> String?
        let observeUpdates: @MainActor (@escaping @MainActor (String?) -> Void) -> Task<Void, Never>?

        static var storeKit: Self {
            Self(
                current: { await Storefront.current?.countryCode },
                observeUpdates: { receive in
                    // Subscribe before starting the initial asynchronous lookup.
                    let updates = Storefront.updates
                    return Task {
                        for await storefront in updates {
                            guard !Task.isCancelled else { return }
                            receive(storefront.countryCode)
                        }
                    }
                }
            )
        }
    }

    nonisolated private static let requestSnapshot = RequestSnapshot()
    static let shared = OpenAIRegionalAvailability(sources: liveSources, snapshot: requestSnapshot)

    /// Request-entry checks can read this from any executor without a main-actor hop.
    nonisolated static var allowsRequests: Bool { requestSnapshot.allowsRequests }
    @Published private(set) var isAvailable = false

    private let sources: Sources
    private let snapshot: RequestSnapshot
    private var started = false
    private var revision: UInt64 = 0
    private var isPublishing = false
    private var onRestriction: (@MainActor () -> Void)?
    private var updatesTask: Task<Void, Never>?
    private var initialTask: Task<Void, Never>?

    /// Injected instances have isolated snapshots; only `shared` publishes request policy.
    init(sources: Sources, snapshot: RequestSnapshot = RequestSnapshot()) {
        self.sources = sources
        self.snapshot = snapshot
    }

    deinit {
        updatesTask?.cancel()
        initialTask?.cancel()
    }

    func start(onRestriction: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        self.onRestriction = onRestriction
        // Mint the initial read's revision BEFORE observing updates. An update arriving
        // before this task runs must also invalidate that not-yet-started read.
        let initialRevision = beginResolution()
        updatesTask = sources.observeUpdates { [weak self] countryCode in
            self?.receiveUpdate(countryCode)
        }
        let current = sources.current
        initialTask = Task { [weak self] in
            guard !Task.isCancelled, self?.revision == initialRevision else { return }
            let countryCode = await current()
            guard !Task.isCancelled else { return }
            self?.completeResolution(countryCode, revision: initialRevision)
        }
    }

    /// Keep the last resolved storefront during foreground re-resolution so an
    /// OAuth browser round trip does not cancel healthy login. An actual unknown
    /// result fails closed; cancelled or superseded reads cannot publish policy.
    func refresh() async {
        guard !Task.isCancelled else { return }
        let currentRevision = beginResolution()
        let countryCode = await sources.current()
        guard !Task.isCancelled else { return }
        completeResolution(countryCode, revision: currentRevision)
    }

    private func beginResolution() -> UInt64 {
        revision &+= 1
        return revision
    }

    private func receiveUpdate(_ countryCode: String?) {
        revision &+= 1
        initialTask?.cancel()
        publish(Self.isAllowed(countryCode: countryCode), revision: revision)
    }

    private func completeResolution(_ countryCode: String?, revision expectedRevision: UInt64) {
        guard expectedRevision == revision else { return }
        publish(Self.isAllowed(countryCode: countryCode), revision: expectedRevision)
    }

    private func publish(_ allowed: Bool, revision expectedRevision: UInt64) {
        guard expectedRevision == revision else { return }
        // Block nonisolated request boundaries before cancelling active work and
        // before notifying UI observers. The callback may synchronously reenter.
        let wasAllowed = snapshot.allowsRequests
        snapshot.setAllowed(allowed)
        if wasAllowed && !allowed { onRestriction?() }
        guard expectedRevision == revision else { return }
        reconcilePublishedAvailability()
    }

    private func reconcilePublishedAvailability() {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        // @Published emits before storing its value. A synchronous subscriber can
        // restrict the storefront during that emission; let the outer setter finish,
        // then reconcile against the latest snapshot instead of nesting setters.
        while isAvailable != snapshot.allowsRequests {
            isAvailable = snapshot.allowsRequests
        }
    }

    /// StoreKit is authoritative for storefront identifiers, including future codes.
    /// Only CHN is restricted; nil and malformed alpha-3 values are unresolved.
    nonisolated static func isAllowed(countryCode: String?) -> Bool {
        guard let countryCode,
              countryCode.utf8.count == 3,
              countryCode.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return false }
        return countryCode != "CHN"
    }

    private static var liveSources: Sources {
        #if SIFT_QA
        if let sources = qaSources(arguments: ProcessInfo.processInfo.arguments) { return sources }
        #endif
        return .storeKit
    }

    #if SIFT_QA
    /// This launch seam is not compiled into the production App Store binary.
    static func qaSources(arguments: [String]) -> Sources? {
        guard let flag = arguments.firstIndex(of: "-sift-test-storefront") else { return nil }
        let value = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "unknown"
        let countryCode: String?
        switch value {
        case "CHN", "KOR", "USA": countryCode = value
        default: countryCode = nil
        }
        return Sources(current: { countryCode }, observeUpdates: { _ in nil })
    }
    #endif
}
