import Combine
import Foundation
import Testing
@testable import todo

/// No StoreKit account, clock, launch environment, or shared request snapshot is used.
@MainActor private final class RegionalStorefrontSource {
    private var pending: [Int: CheckedContinuation<String?, Never>] = [:]
    private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var returnedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var returned = Set<Int>()
    private var receive: (@MainActor (String?) -> Void)?
    private(set) var readCount = 0
    private(set) var observationCount = 0

    var sources: OpenAIRegionalAvailability.Sources {
        .init(current: { await self.current() }, observeUpdates: { receive in
            self.observationCount += 1
            self.receive = receive
            return nil
        })
    }

    private func current() async -> String? {
        let index = readCount
        readCount += 1
        let result: String? = await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = readWaiters.filter { $0.0 <= readCount }
            readWaiters.removeAll { $0.0 <= readCount }
            for (_, waiter) in ready { waiter.resume() }
        }
        returned.insert(index)
        returnedWaiters.removeValue(forKey: index)?.resume()
        // Caller and waiter share MainActor. There is no suspension between this
        // return and the caller's policy commit, so the waiter sees that commit.
        return result
    }

    func waitForReads(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }

    func waitForReturn(_ index: Int) async {
        guard !returned.contains(index) else { return }
        await withCheckedContinuation { returnedWaiters[index] = $0 }
    }

    func resolve(_ index: Int, as countryCode: String?) throws {
        let pendingContinuation = pending.removeValue(forKey: index)
        let continuation = try #require(pendingContinuation)
        // Deliberately ignores cancellation, just as an asynchronous SDK lookup may.
        continuation.resume(returning: countryCode)
    }

    func update(_ countryCode: String?) { receive?(countryCode) }
}

@Suite("OpenAI storefront availability")
@MainActor struct OpenAIRegionalAvailabilityTests {
    @Test("StoreKit-issued non-mainland alpha-3 storefronts are available", arguments: [
        "KOR", "USA", "JPN", "GBR", "FRA", "HKG", "MAC", "TWN", "XKS", "XKX", "ABC", "ZZZ"
    ])
    func availableCountry(_ countryCode: String) {
        #expect(OpenAIRegionalAvailability.isAllowed(countryCode: countryCode))
    }

    @Test("Mainland, unknown and malformed identifiers fail closed", arguments: [
        nil, "CHN", "", "unknown", "CN", "chn", "kor", " USA", "USA\n", "US1", "USＡ"
    ] as [String?])
    func unavailableCountry(_ countryCode: String?) {
        #expect(!OpenAIRegionalAvailability.isAllowed(countryCode: countryCode))
    }

    @Test("Initial policy is closed and isolated snapshots are readable off actor")
    func initialPolicy() async {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        #expect(!gate.isAvailable)
        #expect(source.readCount == 0)
        #expect(source.observationCount == 0)
        let initial = await Task.detached { snapshot.allowsRequests }.value
        #expect(!initial)
        snapshot.setAllowed(true)
        let allowed = await Task.detached { snapshot.allowsRequests }.value
        #expect(allowed)
        snapshot.setAllowed(false)
        let restricted = await Task.detached { snapshot.allowsRequests }.value
        #expect(!restricted)
    }

    @Test("Restrictions block requests and invalidate work before publishing UI")
    func transitions() async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        var events: [String] = []
        let observation = gate.$isAvailable.dropFirst().sink { allowed in
            #expect(snapshot.allowsRequests == allowed)
            events.append("ui:\(allowed)")
        }
        gate.start {
            #expect(!snapshot.allowsRequests)
            events.append("restriction")
        }
        await source.waitForReads(1)
        #expect(!gate.isAvailable)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)
        #expect(gate.isAvailable)

        source.update("CHN")
        #expect(!gate.isAvailable)
        #expect(!snapshot.allowsRequests)
        source.update("CHN")
        source.update(nil)
        source.update("USA")
        #expect(gate.isAvailable)
        source.update(nil)
        #expect(!gate.isAvailable)
        source.update("KOR")
        #expect(gate.isAvailable)
        #expect(events == [
            "ui:true", "restriction", "ui:false", "ui:true", "restriction", "ui:false", "ui:true"
        ])
        withExtendedLifetime(observation) {}
    }

    @Test("Starting twice does not duplicate observers or replace the restriction handler")
    func startsOnce() async throws {
        let source = RegionalStorefrontSource()
        let gate = OpenAIRegionalAvailability(sources: source.sources)
        var restrictions = 0
        var replacementRestrictions = 0
        gate.start { restrictions += 1 }
        gate.start { replacementRestrictions += 1 }
        await source.waitForReads(1)
        #expect(source.observationCount == 1)
        #expect(source.readCount == 1)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)
        source.update("CHN")
        #expect(restrictions == 1)
        #expect(replacementRestrictions == 0)
    }

    @Test("An initial allowed lookup cannot overwrite a newer restriction", arguments: ["CHN", nil] as [String?])
    func initialReadVersusUpdate(_ restriction: String?) async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        var publications: [Bool] = []
        let observation = gate.$isAvailable.sink { publications.append($0) }
        gate.start {}
        await source.waitForReads(1)
        source.update(restriction)
        try source.resolve(0, as: "USA")
        await source.waitForReturn(0)
        #expect(!gate.isAvailable)
        #expect(!snapshot.allowsRequests)
        #expect(publications == [false])
        source.update("KOR")
        #expect(gate.isAvailable)
        #expect(snapshot.allowsRequests)
        withExtendedLifetime(observation) {}
    }

    @Test("Initial current resolution applies mainland, non-mainland and unknown policy", arguments: [
        nil, "CHN", "KOR", "USA", "ZZZ", "XKS"
    ] as [String?])
    func initialResolution(_ countryCode: String?) async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        gate.start {}
        await source.waitForReads(1)
        #expect(!gate.isAvailable)
        #expect(!snapshot.allowsRequests)
        try source.resolve(0, as: countryCode)
        await source.waitForReturn(0)
        let expected = countryCode == "KOR" || countryCode == "USA" || countryCode == "ZZZ" || countryCode == "XKS"
        #expect(gate.isAvailable == expected)
        #expect(snapshot.allowsRequests == expected)
    }

    @Test("Foreground refresh preserves a known storefront until an actual unknown result")
    func refreshPreservesResolvedPolicy() async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        var restrictions = 0
        gate.start { restrictions += 1 }
        await source.waitForReads(1)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)

        let foreground = Task { await gate.refresh() }
        await source.waitForReads(2)
        #expect(gate.isAvailable)
        #expect(snapshot.allowsRequests)
        #expect(restrictions == 0)
        try source.resolve(1, as: "USA")
        await foreground.value
        #expect(gate.isAvailable)
        #expect(restrictions == 0)

        let unknown = Task { await gate.refresh() }
        await source.waitForReads(3)
        #expect(gate.isAvailable)
        try source.resolve(2, as: nil)
        await unknown.value
        #expect(!gate.isAvailable)
        #expect(!snapshot.allowsRequests)
        #expect(restrictions == 1)
    }

    @Test("An update invalidates an in-flight foreground allowed result", arguments: ["CHN", nil] as [String?])
    func refreshVersusUpdate(_ restriction: String?) async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        var restrictions = 0
        gate.start { restrictions += 1 }
        await source.waitForReads(1)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)
        let foreground = Task { await gate.refresh() }
        await source.waitForReads(2)
        source.update(restriction)
        #expect(!snapshot.allowsRequests)
        #expect(restrictions == 1)
        try source.resolve(1, as: "USA")
        await foreground.value
        #expect(!gate.isAvailable)
        #expect(!snapshot.allowsRequests)
        #expect(restrictions == 1)
    }

    @Test("The newest overlapping refresh owns policy even when older reads finish last", arguments: [false, true])
    func overlappingRefreshes(latestIsAllowed: Bool) async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        let older = Task { await gate.refresh() }
        await source.waitForReads(1)
        let newer = Task { await gate.refresh() }
        await source.waitForReads(2)
        try source.resolve(1, as: latestIsAllowed ? "KOR" : nil)
        await newer.value
        try source.resolve(0, as: latestIsAllowed ? "CHN" : "USA")
        await older.value
        #expect(gate.isAvailable == latestIsAllowed)
        #expect(snapshot.allowsRequests == latestIsAllowed)

        let latest = Task { await gate.refresh() }
        await source.waitForReads(3)
        try source.resolve(2, as: "KOR")
        await latest.value
        #expect(gate.isAvailable)
        #expect(snapshot.allowsRequests)
    }

    @Test("Cancelled resolutions cannot enable an unresolved storefront")
    func cancelledAllowedResolution() async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        let refresh = Task { await gate.refresh() }
        await source.waitForReads(1)
        refresh.cancel()
        try source.resolve(0, as: "USA")
        await refresh.value
        #expect(!gate.isAvailable)
        #expect(!snapshot.allowsRequests)
    }

    @Test("Cancelled resolutions do not invalidate a healthy known storefront")
    func cancelledUnknownResolution() async throws {
        let source = RegionalStorefrontSource()
        let gate = OpenAIRegionalAvailability(sources: source.sources)
        gate.start {}
        await source.waitForReads(1)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)
        let refresh = Task { await gate.refresh() }
        await source.waitForReads(2)
        refresh.cancel()
        try source.resolve(1, as: nil)
        await refresh.value
        #expect(gate.isAvailable)
    }

    @Test("A restriction handler's reentrant newer update is not overwritten")
    func reentrantRestriction() async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        var restrictions = 0
        gate.start {
            restrictions += 1
            #expect(!snapshot.allowsRequests)
            source.update("USA")
        }
        await source.waitForReads(1)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)
        source.update("CHN")
        #expect(restrictions == 1)
        #expect(gate.isAvailable)
        #expect(snapshot.allowsRequests)
    }

    @Test("A synchronous published-value subscriber cannot leave restricted UI available", arguments: ["CHN", nil] as [String?])
    func reentrantPublishedRestriction(_ restriction: String?) async throws {
        let source = RegionalStorefrontSource()
        let snapshot = OpenAIRegionalAvailability.RequestSnapshot()
        let gate = OpenAIRegionalAvailability(sources: source.sources, snapshot: snapshot)
        var publications: [Bool] = []
        var restrictions = 0
        let observation = gate.$isAvailable.sink { allowed in
            publications.append(allowed)
            if allowed {
                source.update(restriction)
                #expect(!snapshot.allowsRequests)
            }
        }
        gate.start {
            restrictions += 1
            #expect(!snapshot.allowsRequests)
        }
        await source.waitForReads(1)
        try source.resolve(0, as: "KOR")
        await source.waitForReturn(0)
        #expect(restrictions == 1)
        #expect(!snapshot.allowsRequests)
        #expect(!gate.isAvailable)
        #expect(publications == [false, true, false])
        withExtendedLifetime(observation) {}
    }

    #if SIFT_QA
    @Test("The QA launch seam is explicit and deterministic")
    func qaLaunchOverride() async throws {
        #expect(OpenAIRegionalAvailability.qaSources(arguments: ["SIFT QA"]) == nil)
        for (value, expected) in [("CHN", false), ("KOR", true), ("USA", true), ("unknown", false), ("ZZZ", false)] {
            let sources = try #require(OpenAIRegionalAvailability.qaSources(arguments: ["SIFT QA", "-sift-test-storefront", value]))
            let gate = OpenAIRegionalAvailability(sources: sources)
            #expect(!gate.isAvailable)
            await gate.refresh()
            #expect(gate.isAvailable == expected)
        }
        let missingValue = try #require(OpenAIRegionalAvailability.qaSources(arguments: ["SIFT QA", "-sift-test-storefront"]))
        let gate = OpenAIRegionalAvailability(sources: missingValue)
        await gate.refresh()
        #expect(!gate.isAvailable)
    }
    #endif
}
