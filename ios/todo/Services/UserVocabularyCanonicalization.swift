import Foundation

struct VocabularyCanonicalizationEngine {
    typealias Availability = @Sendable () async -> Bool
    typealias Generate = @Sendable (VocabularyEnrichmentRequest) async throws -> [VocabularyCanonicalizationProposal]

    private let foundationModelsAvailable: Availability
    private let foundationGenerate: Generate
    private let qwenLoaded: Availability
    private let qwenGenerate: Generate

    nonisolated init(
        foundationModelsAvailable: Availability? = nil,
        foundationGenerate: @escaping Generate = { _ in [] },
        qwenLoaded: @escaping Availability = { false },
        qwenGenerate: @escaping Generate = { _ in [] }
    ) {
        self.foundationModelsAvailable = foundationModelsAvailable ?? Self.defaultFoundationModelsAvailable
        self.foundationGenerate = foundationGenerate
        self.qwenLoaded = qwenLoaded
        self.qwenGenerate = qwenGenerate
    }

    nonisolated private static func defaultFoundationModelsAvailable() async -> Bool {
        await MainActor.run { FoundationModelsAvailability.isAvailable }
    }

    func enrich(_ request: VocabularyEnrichmentRequest) async -> VocabularyEnrichmentOutcome {
        if await foundationModelsAvailable() {
            do { return .completed(try await foundationGenerate(request)) }
            catch { }
        }
        guard await qwenLoaded() else { return .unavailable }
        do { return .completed(try await qwenGenerate(request)) }
        catch { return .failed }
    }
}

actor VocabularyEnrichmentQueue {
    private struct QueueKey: Hashable {
        let sourceKey: String
        let contentFingerprint: String
        let extractorVersion: Int
        let generation: UUID
        let canonicalizationVersion: Int

        init(_ token: VocabularyEnrichmentRequest.Token) {
            self.sourceKey = token.sourceKey
            self.contentFingerprint = token.contentFingerprint
            self.extractorVersion = token.extractorVersion
            self.generation = token.generation
            self.canonicalizationVersion = token.canonicalizationVersion
        }
    }

    private let service: UserVocabularyService
    private let engine: VocabularyCanonicalizationEngine
    private var pending: [QueueKey: VocabularyEnrichmentRequest] = [:]
    private var order: [QueueKey] = []
    private var worker: Task<Void, Never>?

    init(service: UserVocabularyService, engine: VocabularyCanonicalizationEngine = VocabularyCanonicalizationEngine()) {
        self.service = service
        self.engine = engine
    }

    func enqueue(_ request: VocabularyEnrichmentRequest) {
        let key = QueueKey(request.token)
        if pending.index(forKey: key) == nil { order.append(key) }
        pending[key] = request
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    func cancelAll() async {
        worker?.cancel()
        _ = await worker?.value
        worker = nil
        order.removeAll(); pending.removeAll()
    }

    private func drain() async {
        defer { worker = nil }
        while !Task.isCancelled, let token = order.first {
            order.removeFirst()
            guard let request = pending.removeValue(forKey: token) else { continue }
            let outcome = await engine.enrich(request)
            do {
                switch outcome {
                case .completed(let proposals):
                    _ = try await service.applyEnrichment(requestToken: request.token, canonicalizationVersion: request.token.canonicalizationVersion, proposals: proposals)
                case .unavailable:
                    try await service.recordEnrichmentFailure(requestToken: request.token, unavailable: true)
                case .failed:
                    try await service.recordEnrichmentFailure(requestToken: request.token, unavailable: false)
                }
            } catch { }
        }
    }
}
