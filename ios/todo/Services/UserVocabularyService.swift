import CryptoKit
import Foundation
import Security
import SwiftData

/// Immutable per-key portable entries prevent last-writer-wins key loss.
nonisolated struct HMACIdentityKeyFamily {
    private static let lock = NSLock()
    let service: String
    let primaryAccount: String

    nonisolated struct Authorization: Sendable {
        let isEnabled: Bool
        private let lease: @Sendable () -> Bool

        init() {
            #if DEBUG
            let capture = HMACIdentityKeyFamily.captureAuthorizationForTesting
                ?? { UserCloudSyncPolicy.captureAuthorization() }
            #else
            let capture = { UserCloudSyncPolicy.captureAuthorization() }
            #endif
            let captured = capture()
            lease = captured
            isEnabled = captured()
        }

        func requireCurrent() throws {
            if isEnabled { try KeychainStore.requirePortableAuthorization(lease) }
        }
    }

    #if DEBUG
    // Fixtures hold AIProviderTestIsolation for the entire override lifetime.
    nonisolated(unsafe) static var captureAuthorizationForTesting: (@Sendable () -> @Sendable () -> Bool)?
    #endif
    private var cacheAccount: String { primaryAccount + ".family-v1" }
    private var portablePrefix: String { primaryAccount + ".member-v1." }

    static func identifier(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func keys(
        createIfMissing: Bool,
        legacyKeys: ((Authorization) throws -> [Data])? = nil,
        authorization: Authorization = Authorization()
    ) throws -> [Data] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let primary = try KeychainStore.getDeviceOnly(service: service, account: primaryAccount)
        let cached = try KeychainStore.getDeviceOnly(service: service, account: cacheAccount)
        var keys: [Data] = []
        func append(_ key: Data) throws {
            guard key.count == 32 else { throw VocabularyServiceError.invalidKey }
            if !keys.contains(key) { keys.append(key) }
        }
        if let primary { try append(primary) }
        if let cached {
            for key in try JSONDecoder().decode([Data].self, from: cached) { try append(key) }
        }
        for legacy in try legacyKeys?(authorization) ?? [] { try append(legacy) }
        var portable: [String: Data] = [:]
        if authorization.isEnabled {
            try authorization.requireCurrent()
            for account in try KeychainStore.synchronizableAccounts(service: service) where account.hasPrefix(portablePrefix) {
                try authorization.requireCurrent()
                guard let key = try KeychainStore.getSynchronizable(service: service, account: account) else {
                    // Enumeration and reads are not an atomic Keychain snapshot.
                    throw KeychainStoreError.security(errSecItemNotFound)
                }
                guard account == portablePrefix + Self.identifier(key) else { throw VocabularyServiceError.invalidKey }
                try append(key)
                portable[account] = key
            }
        }
        // A revoked read must not turn into absence or a replacement identity.
        try authorization.requireCurrent()
        if keys.isEmpty && createIfMissing {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw VocabularyServiceError.keyGeneration
            }
            keys.append(Data(bytes))
        }
        guard let first = keys.first else {
            try authorization.requireCurrent()
            return []
        }
        // Finish reads and publication before importing portable data locally.
        let encoded = try JSONEncoder().encode(keys)
        if authorization.isEnabled {
            for key in keys {
                let account = portablePrefix + Self.identifier(key)
                if portable[account] == nil {
                    try authorization.requireCurrent()
                    try KeychainStore.setSynchronizable(service: service, account: account, data: key)
                }
            }
        }
        if cached != encoded {
            try authorization.requireCurrent()
            try KeychainStore.setDeviceOnly(service: service, account: cacheAccount, data: encoded)
        }
        if primary == nil {
            try authorization.requireCurrent()
            try KeychainStore.setDeviceOnly(service: service, account: primaryAccount, data: first)
        }
        try authorization.requireCurrent()
        return keys
    }

    func applyFullSyncPolicy(legacyKeys: ((Authorization) throws -> [Data])? = nil,
                             authorization: Authorization = .init()) throws {
        guard authorization.isEnabled else { return }
        _ = try keys(createIfMissing: false, legacyKeys: legacyKeys, authorization: authorization)
        try authorization.requireCurrent()
    }
}

actor VocabularyHMACKeyStore {
    private let family = HMACIdentityKeyFamily(service: "pieroot.todo.vocabulary", primaryAccount: "hmac-key-v1")

    func readOrCreate() throws -> Data {
        try keys().first!
    }

    func keys(matching verifiers: [String] = [], authorization: HMACIdentityKeyFamily.Authorization = .init()) throws -> [Data] {
        var keys = try family.keys(createIfMissing: verifiers.allSatisfy(\.isEmpty), authorization: authorization)
        guard !keys.isEmpty else { throw VocabularyServiceError.originalKeyUnavailable }
        if let index = keys.firstIndex(where: { verifiers.contains(Self.verifier($0)) }) {
            let matching = keys.remove(at: index)
            keys.insert(matching, at: 0)
        }
        return keys
    }

    /// Disabling full sync never deletes a portable or local key.
    func applyFullSyncPolicy(authorization: HMACIdentityKeyFamily.Authorization = .init()) async throws {
        try family.applyFullSyncPolicy(authorization: authorization)
    }

    nonisolated static func verifier(_ key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("SIFT User Vocabulary v1".utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum VocabularyServiceError: Error, Equatable {
    case invalidKey
    case keyGeneration
    case originalKeyUnavailable
    case invalidDraft
    case missingTerm
}

@ModelActor
actor UserVocabularyService {

    private let keyStore = VocabularyHMACKeyStore()
    private let now: @Sendable () -> Date = Date.init
    private let makeGeneration: @Sendable () -> UUID = UUID.init
    private var initialized = false
    private var hmacKeys: [Data] = []
    func observe(_ document: VocabularySourceDocument, forceEnrichment: Bool = false) async throws -> VocabularyEnrichmentRequest? {
        try await ensureInitialized()
        let candidates = await UserVocabularyExtractor().extract(from: document)
        let sourceKeys = provenanceKeys(for: document.stableID)
        let states = try modelContext.fetch(FetchDescriptor<VocabularySourceState>())
        let existing = states.first { sourceKeys.contains($0.sourceKey) }
        let originalKey = existing.flatMap { state in hmacKeys.first { hmac(document.stableID, key: $0) == state.sourceKey } }
        let sourceKey = existing?.sourceKey ?? hmac(document.stableID)
        let evidenceKey = hmac(document.evidenceGroupID, key: originalKey)
        if let existing, existing.contentFingerprint == document.contentFingerprint, existing.extractorVersion == UserVocabularyExtractor.version {
            if existing.enrichmentStatusRaw == VocabularyEnrichmentStatus.failed.rawValue,
               forceEnrichment || (now().timeIntervalSince(existing.lastEnrichmentAttemptAt ?? .distantPast) >= 86_400) {
                existing.enrichmentStatusRaw = VocabularyEnrichmentStatus.pending.rawValue
                existing.lastEnrichmentAttemptAt = now()
                try modelContext.save()
            } else {
                return nil
            }
        }

        let generation = makeGeneration()
        if let existing {
            let observations = try modelContext.fetch(FetchDescriptor<VocabularyObservation>(predicate: #Predicate { $0.sourceKey == sourceKey }))
            observations.forEach(modelContext.delete)
            existing.evidenceGroupKey = evidenceKey
            existing.sourceKindRaw = document.source.rawValue
            existing.contentFingerprint = document.contentFingerprint
            existing.extractorVersion = UserVocabularyExtractor.version
            existing.generation = generation
            existing.enrichmentVersion = UserVocabularyExtractor.version
            existing.updatedAt = now()
            existing.enrichmentStatusRaw = candidates.isEmpty ? VocabularyEnrichmentStatus.notNeeded.rawValue : VocabularyEnrichmentStatus.pending.rawValue
            existing.lastEnrichmentAttemptAt = candidates.isEmpty ? nil : now()
        } else {
            let state = VocabularySourceState()
            state.sourceKey = sourceKey
            state.evidenceGroupKey = evidenceKey
            state.sourceKindRaw = document.source.rawValue
            state.contentFingerprint = document.contentFingerprint
            state.extractorVersion = UserVocabularyExtractor.version
            state.generation = generation
            state.enrichmentVersion = UserVocabularyExtractor.version
            state.enrichmentStatusRaw = candidates.isEmpty ? VocabularyEnrichmentStatus.notNeeded.rawValue : VocabularyEnrichmentStatus.pending.rawValue
            state.lastEnrichmentAttemptAt = candidates.isEmpty ? nil : now()
            state.updatedAt = now()
            modelContext.insert(state)
        }
        for candidate in candidates {
            let observation = VocabularyObservation()
            observation.canonicalDisplay = candidate.canonical
            observation.canonicalKey = Self.normalizedKey(candidate.canonical)
            observation.sourceKey = sourceKey
            observation.sourceGeneration = generation
            observation.evidenceGroupKey = evidenceKey
            observation.surfaceDisplay = candidate.surface
            observation.surfaceKey = Self.normalizedKey(candidate.surface)
            observation.roleRaw = candidate.role.rawValue
            observation.evidenceKindRaw = VocabularyEvidenceKind.exact.rawValue
            observation.categoryRaw = candidate.category.rawValue
            observation.confidence = candidate.confidence
            observation.observedAt = now()
            modelContext.insert(observation)
        }
        try rebuildTerms()
        try modelContext.save()
        guard !candidates.isEmpty else { return nil }
        return VocabularyEnrichmentRequest(
            token: .init(sourceKey: sourceKey, contentFingerprint: document.contentFingerprint, extractorVersion: UserVocabularyExtractor.version, generation: generation, canonicalizationVersion: UserVocabularyExtractor.version),
            candidates: candidates.prefix(12).map { $0 },
            context: document.fields.map(\.value).joined(separator: "\n").prefix(2_880).description
        )
    }

    func applyEnrichment(requestToken: VocabularyEnrichmentRequest.Token, canonicalizationVersion: Int, proposals: [VocabularyCanonicalizationProposal]) async throws -> Bool {
        try await ensureInitialized()
        let states = try modelContext.fetch(FetchDescriptor<VocabularySourceState>()).filter { $0.sourceKey == requestToken.sourceKey }
        guard let state = states.first,
              state.contentFingerprint == requestToken.contentFingerprint,
              state.extractorVersion == requestToken.extractorVersion,
              state.generation == requestToken.generation,
              canonicalizationVersion == requestToken.canonicalizationVersion
        else { return false }
        let observations = try modelContext.fetch(FetchDescriptor<VocabularyObservation>()).filter {
            $0.sourceKey == requestToken.sourceKey
                && $0.sourceGeneration == requestToken.generation
                && $0.evidenceKindRaw == VocabularyEvidenceKind.modelProposal.rawValue
        }
        observations.forEach(modelContext.delete)
        for proposal in proposals {
            guard validSurface(proposal.canonical) else { continue }
            let canonical = VocabularyObservation()
            canonical.canonicalDisplay = proposal.canonical
            canonical.canonicalKey = Self.normalizedKey(proposal.canonical)
            canonical.sourceKey = state.sourceKey
            canonical.sourceGeneration = state.generation
            canonical.evidenceGroupKey = state.evidenceGroupKey
            canonical.surfaceDisplay = proposal.canonical
            canonical.surfaceKey = canonical.canonicalKey
            canonical.roleRaw = VocabularyObservationRole.canonical.rawValue
            canonical.evidenceKindRaw = VocabularyEvidenceKind.modelProposal.rawValue
            canonical.categoryRaw = proposal.category.rawValue
            canonical.confidence = 0
            canonical.observedAt = now()
            modelContext.insert(canonical)
            if let alias = proposal.speechAlias, validSurface(alias), Self.normalizedKey(alias) != canonical.canonicalKey {
                let speech = VocabularyObservation()
                speech.canonicalDisplay = proposal.canonical
                speech.canonicalKey = canonical.canonicalKey
                speech.sourceKey = state.sourceKey
                speech.sourceGeneration = state.generation
                speech.evidenceGroupKey = state.evidenceGroupKey
                speech.surfaceDisplay = alias
                speech.surfaceKey = Self.normalizedKey(alias)
                speech.roleRaw = VocabularyObservationRole.speechAlias.rawValue
                speech.evidenceKindRaw = VocabularyEvidenceKind.modelProposal.rawValue
                speech.categoryRaw = proposal.category.rawValue
                speech.observedAt = now()
                modelContext.insert(speech)
            }
        }
        state.enrichmentStatusRaw = VocabularyEnrichmentStatus.completed.rawValue
        state.enrichmentVersion = canonicalizationVersion
        try rebuildTerms()
        try modelContext.save()
        return true
    }

    func recordEnrichmentFailure(requestToken: VocabularyEnrichmentRequest.Token, unavailable: Bool) async throws {
        try await ensureInitialized()
        guard let state = try modelContext.fetch(FetchDescriptor<VocabularySourceState>()).first(where: { $0.sourceKey == requestToken.sourceKey }),
              state.generation == requestToken.generation,
              state.contentFingerprint == requestToken.contentFingerprint else { return }
        state.enrichmentStatusRaw = unavailable ? VocabularyEnrichmentStatus.pending.rawValue : VocabularyEnrichmentStatus.failed.rawValue
        state.enrichmentFailureCount += unavailable ? 0 : 1
        state.lastEnrichmentAttemptAt = now()
        try modelContext.save()
    }

    func learnFromEdit(meetingID: String, segmentID: String, before: String, after: String) async throws {
        try await ensureInitialized()
        let pairs = Self.replacementPairs(before: before, after: after)
        let id = "transcriptEdit\u{0}\(meetingID)\u{0}\(segmentID)"
        let document = VocabularySourceDocumentBuilder.make(source: .transcriptEdit, stableID: id, evidenceGroupID: id, fields: pairs.flatMap { [VocabularyTextField(.transcript, $0.from), VocabularyTextField(.transcript, $0.to)] })
        _ = try await observe(document, forceEnrichment: false)
        let keys = Set(pairs.map { Self.normalizedKey($0.to) })
        let terms = try modelContext.fetch(FetchDescriptor<MeetingGlossaryTerm>())
        for term in terms where keys.contains(term.canonicalKey) {
            term.userConfirmedAt = now()
            term.variants = unique(term.variants + pairs.filter { Self.normalizedKey($0.to) == term.canonicalKey }.map(\.from))
        }
        try modelContext.save()
    }

    func learnFromCorrection(meetingID: String, correctionFingerprint: String, pairs: [(from: String, to: String)]) async throws {
        try await ensureInitialized()
        let id = "transcriptCorrection\u{0}\(meetingID)"
        let document = VocabularySourceDocumentBuilder.make(
            source: .transcriptCorrection,
            stableID: id,
            evidenceGroupID: id,
            fields: pairs.flatMap { [VocabularyTextField(.transcript, $0.from), VocabularyTextField(.transcript, $0.to)] }
        )
        _ = try await observe(document, forceEnrichment: false)
        let sourceKeys = provenanceKeys(for: id)
        guard let state = try modelContext.fetch(FetchDescriptor<VocabularySourceState>()).first(where: { sourceKeys.contains($0.sourceKey) }) else { return }
        for pair in pairs where validSurface(pair.from) && validSurface(pair.to) && Self.normalizedKey(pair.from) != Self.normalizedKey(pair.to) {
            let observation = VocabularyObservation()
            observation.canonicalKey = Self.normalizedKey(pair.to)
            observation.canonicalDisplay = pair.to
            observation.sourceKey = state.sourceKey
            observation.sourceGeneration = state.generation
            observation.evidenceGroupKey = state.evidenceGroupKey
            observation.surfaceKey = Self.normalizedKey(pair.from)
            observation.surfaceDisplay = pair.from
            observation.roleRaw = VocabularyObservationRole.variant.rawValue
            observation.evidenceKindRaw = VocabularyEvidenceKind.transcriptCorrection.rawValue
            observation.categoryRaw = VocabularyCategory.other.rawValue
            observation.confidence = 1
            observation.observedAt = now()
            modelContext.insert(observation)
        }
        try rebuildTerms()
        try modelContext.save()
    }

    func snapshot(contextualLimit: Int = 100, promptCharCap: Int = 400) async -> UserVocabularySnapshot {
        do {
            try await ensureInitialized()
            let terms = try modelContext.fetch(FetchDescriptor<MeetingGlossaryTerm>()).filter(isPromoted).sorted(by: rank)
            let protected = terms.map(\.canonical)
            var speech: [String] = []
            var mappings: [VocabularyCanonicalizationMapping] = []
            let promotedKeys = Set(terms.map(\.canonicalKey))
            for term in terms {
                appendUnique(term.canonical, to: &speech)
                term.userSpeechAliases.forEach { appendUnique($0, to: &speech) }
                for alias in unique(term.userCanonicalizationAliases + term.variants) {
                    let aliasKey = Self.normalizedKey(alias)
                    guard aliasKey != term.canonicalKey, !promotedKeys.contains(aliasKey) else { continue }
                    mappings.append(.init(alias: alias, aliasKey: aliasKey, canonical: term.canonical, canonicalKey: term.canonicalKey, origin: .user))
                }
            }
            var seenAliases = Set<String>()
            mappings = mappings.filter { seenAliases.insert($0.aliasKey).inserted }
            let strings = Array(speech.prefix(max(0, min(contextualLimit, 100))))
            var lines: [String] = []
            var used = 0
            for mapping in mappings {
                let line = "- \(mapping.alias) → \(mapping.canonical)"
                guard used + line.count + 1 <= max(0, min(promptCharCap, 400)) else { continue }
                lines.append(line); used += line.count + 1
            }
            let hint = lines.joined(separator: "\n")
            let digest = Self.hex(SHA256.hash(data: Data((strings + protected + mappings.flatMap { [$0.aliasKey, $0.canonicalKey] } + [hint]).joined(separator: "\u{0}").utf8)))
            return .init(revisionHash: digest, contextualStrings: strings, protectedCanonicalPhrases: protected, canonicalizationMappings: mappings, promptHint: hint)
        } catch {
            return UserVocabularySnapshot(
                revisionHash: "",
                contextualStrings: [],
                protectedCanonicalPhrases: [],
                canonicalizationMappings: [],
                promptHint: ""
            )
        }
    }

    func shouldRunBackfill(extractorVersion: Int, force: Bool) async throws -> Bool {
        try await ensureInitialized()
        let metadata = try metadata()
        guard !force else { return true }
        guard metadata.lastCompletedBackfillExtractorVersion == extractorVersion else { return true }
        return metadata.lastCompletedBackfillAt.map { now().timeIntervalSince($0) >= 86_400 } ?? true
    }

    func markBackfillCompleted(extractorVersion: Int) async throws {
        try await ensureInitialized()
        let metadata = try metadata()
        metadata.lastCompletedBackfillAt = now()
        metadata.lastCompletedBackfillExtractorVersion = extractorVersion
        try modelContext.save()
    }

    func list(query: String = "") async throws -> [VocabularyTermSummary] {
        try await ensureInitialized()
        let needle = Self.normalizedKey(query)
        return try modelContext.fetch(FetchDescriptor<MeetingGlossaryTerm>())
            .filter { needle.isEmpty || Self.normalizedKey($0.canonical).contains(needle) || $0.variants.contains { Self.normalizedKey($0).contains(needle) } }
            .sorted(by: rank)
            .map(summary)
    }

    func addManual(_ draft: VocabularyTermDraft) async throws { try await writeDraft(draft, existingKey: nil) }
    func update(canonicalKey: String, with draft: VocabularyTermDraft) async throws { try await writeDraft(draft, existingKey: canonicalKey) }

    func confirm(canonicalKey: String) async throws {
        try await ensureInitialized()
        guard let term = try term(for: canonicalKey) else { throw VocabularyServiceError.missingTerm }
        term.userConfirmedAt = now(); term.rejectedAt = nil
        try modelContext.save()
    }

    func reject(canonicalKey: String) async throws {
        try await ensureInitialized()
        guard let term = try term(for: canonicalKey) else { throw VocabularyServiceError.missingTerm }
        term.rejectedAt = now(); try modelContext.save()
    }

    func allowRelearning(canonicalKey: String) async throws {
        try await ensureInitialized()
        guard let term = try term(for: canonicalKey) else { throw VocabularyServiceError.missingTerm }
        term.rejectedAt = nil; try modelContext.save()
    }

    func removeRejected(canonicalKey: String) async throws {
        try await ensureInitialized()
        guard let term = try term(for: canonicalKey), term.rejectedAt != nil else {
            throw VocabularyServiceError.missingTerm
        }
        let observations = try modelContext.fetch(FetchDescriptor<VocabularyObservation>()).filter {
            $0.canonicalKey == canonicalKey || $0.surfaceKey == canonicalKey
        }
        observations.forEach(modelContext.delete)
        modelContext.delete(term)
        try modelContext.save()
    }

    func resetAll() async throws {
        try await ensureInitialized()
        try modelContext.delete(model: VocabularyObservation.self)
        try modelContext.delete(model: VocabularySourceState.self)
        try modelContext.delete(model: MeetingGlossaryTerm.self)
        let metadata = try metadata()
        metadata.lastCompletedBackfillAt = nil
        try modelContext.save()
    }

    /// Call after a policy change or delayed Keychain delivery.
    func applyFullSyncPolicy() async throws {
        let authorization = HMACIdentityKeyFamily.Authorization()
        guard authorization.isEnabled else { return }
        try await keyStore.applyFullSyncPolicy(authorization: authorization)
        try authorization.requireCurrent()
        initialized = false
        try await ensureInitialized(authorization: authorization)
        try authorization.requireCurrent()
    }

    private func ensureInitialized(authorization: HMACIdentityKeyFamily.Authorization = .init()) async throws {
        guard !initialized || authorization.isEnabled else { return }
        let rows = try modelContext.fetch(FetchDescriptor<VocabularyStoreMetadata>())
        let resolvedKeys = try await keyStore.keys(matching: rows.map(\.hmacVerifier), authorization: authorization)
        try authorization.requireCurrent()
        hmacKeys = resolvedKeys
        let metadata = try metadata()
        if metadata.schemaRepairVersion < 1 {
            try repairLegacyTerms()
            metadata.schemaRepairVersion = 1
        }
        // Foreign metadata can arrive before its original key. Preserve both the
        // verifier and learned rows for later Keychain delivery, never reset them.
        if metadata.hmacVerifier.isEmpty, let key = hmacKeys.first {
            metadata.hmacVerifier = VocabularyHMACKeyStore.verifier(key)
        }
        try authorization.requireCurrent()
        try modelContext.save()
        try authorization.requireCurrent()
        initialized = true
    }

    private func metadata() throws -> VocabularyStoreMetadata {
        if let metadata = try modelContext.fetch(FetchDescriptor<VocabularyStoreMetadata>()).first { return metadata }
        let metadata = VocabularyStoreMetadata(); modelContext.insert(metadata); return metadata
    }

    private func repairLegacyTerms() throws {
        let terms = try modelContext.fetch(FetchDescriptor<MeetingGlossaryTerm>())
        let groups = Dictionary(grouping: terms) { Self.normalizedKey($0.canonical) }
        for (key, rows) in groups where !key.isEmpty {
            let priority: (MeetingGlossaryTerm) -> Int = {
                switch $0.source {
                case MeetingGlossaryTerm.Source.manual.rawValue: return 3
                case MeetingGlossaryTerm.Source.editDiff.rawValue: return 2
                default: return 1
                }
            }
            let winner = rows.sorted {
                if priority($0) != priority($1) { return priority($0) > priority($1) }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.canonical < $1.canonical
            }[0]
            winner.canonicalKey = key
            winner.category = winner.category == "term"
                ? VocabularyCategory.technicalTerm.rawValue
                : (VocabularyCategory(rawValue: winner.category) ?? .other).rawValue
            winner.variants = unique(rows.flatMap(\.variants))
            winner.userSpeechAliases = unique(rows.flatMap(\.userSpeechAliases))
            winner.userCanonicalizationAliases = unique(rows.flatMap(\.userCanonicalizationAliases))
            winner.frequency = rows.map(\.frequency).reduce(0, +)
            winner.createdAt = rows.map(\.createdAt).min() ?? winner.createdAt
            winner.updatedAt = rows.map(\.updatedAt).max() ?? winner.updatedAt
            winner.lastSeenAt = rows.map(\.lastSeenAt).max() ?? winner.lastSeenAt
            if rows.contains(where: { $0.source == MeetingGlossaryTerm.Source.manual.rawValue || $0.source == MeetingGlossaryTerm.Source.editDiff.rawValue }) {
                winner.userConfirmedAt = winner.updatedAt
            }
            winner.confirmedLegacy = rows.allSatisfy { $0.source == MeetingGlossaryTerm.Source.correction.rawValue } && winner.frequency >= 2
            if rows.allSatisfy({ $0.source == MeetingGlossaryTerm.Source.correction.rawValue && $0.reverted }) {
                winner.rejectedAt = winner.updatedAt
            }
            for row in rows where row !== winner { modelContext.delete(row) }
        }
    }

    private func rebuildTerms() throws {
        let observations = try modelContext.fetch(FetchDescriptor<VocabularyObservation>())
        let terms = try modelContext.fetch(FetchDescriptor<MeetingGlossaryTerm>())
        let stateKinds = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<VocabularySourceState>()).map { ($0.sourceKey, $0.sourceKindRaw) })
        let grouped = Dictionary(grouping: observations, by: \.canonicalKey)
        for (key, group) in grouped {
            let term = terms.first(where: { $0.canonicalKey == key }) ?? MeetingGlossaryTerm(canonical: group[0].canonicalDisplay)
            if !terms.contains(where: { $0 === term }) { modelContext.insert(term) }
            term.canonicalKey = key
            let best = group.sorted { $0.confidence > $1.confidence }.first!
            if !term.isDisplayUserEdited { term.canonical = best.canonicalDisplay }
            if !term.isCategoryUserEdited { term.category = best.categoryRaw }
            term.frequency = group.count
            term.lastSeenAt = group.map(\.observedAt).max() ?? now()
            term.updatedAt = now()
            term.exactEvidenceGroupCount = Set(group.filter { $0.evidenceKindRaw == VocabularyEvidenceKind.exact.rawValue }.map(\.evidenceGroupKey)).count
            term.highConfidenceExactEvidenceGroupCount = Set(group.filter { $0.evidenceKindRaw == VocabularyEvidenceKind.exact.rawValue && $0.confidence >= 0.9 }.map(\.evidenceGroupKey)).count
            term.correctionEvidenceGroupCount = Set(group.filter { $0.evidenceKindRaw == VocabularyEvidenceKind.transcriptCorrection.rawValue }.map(\.evidenceGroupKey)).count
            term.automaticMaxConfidence = group.map(\.confidence).max() ?? 0
            term.observedSourceKinds = Array(Set(group.compactMap { stateKinds[$0.sourceKey] })).sorted()
        }
    }

    private func writeDraft(_ draft: VocabularyTermDraft, existingKey: String?) async throws {
        try await ensureInitialized()
        let canonical = draft.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSurface(canonical) else { throw VocabularyServiceError.invalidDraft }
        let key = Self.normalizedKey(canonical)
        let existingTerm = try term(for: existingKey ?? key)
        let term = existingTerm ?? MeetingGlossaryTerm(canonical: canonical)
        if existingTerm == nil { modelContext.insert(term) }
        term.canonical = canonical; term.canonicalKey = key; term.category = draft.category.rawValue
        term.userSpeechAliases = unique(draft.speechAliases.filter(validSurface))
        term.userCanonicalizationAliases = unique(draft.canonicalizationAliases.filter(validSurface))
        term.variants = unique(draft.variants.filter(validSurface))
        term.isDisplayUserEdited = true; term.isCategoryUserEdited = true; term.userConfirmedAt = now(); term.rejectedAt = nil
        try modelContext.save()
    }

    private func term(for key: String?) throws -> MeetingGlossaryTerm? {
        guard let key else { return nil }
        return try modelContext.fetch(FetchDescriptor<MeetingGlossaryTerm>(predicate: #Predicate { $0.canonicalKey == key })).first
    }

    private func isPromoted(_ term: MeetingGlossaryTerm) -> Bool {
        guard term.rejectedAt == nil, term.redirectCanonicalKey.isEmpty, !term.canonical.isEmpty else { return false }
        return term.userConfirmedAt != nil || term.confirmedLegacy || term.correctionEvidenceGroupCount >= 2 || term.highConfidenceExactEvidenceGroupCount >= 2 || term.exactEvidenceGroupCount >= 3
    }

    private func rank(_ lhs: MeetingGlossaryTerm, _ rhs: MeetingGlossaryTerm) -> Bool {
        if isPromoted(lhs) != isPromoted(rhs) { return isPromoted(lhs) }
        if lhs.exactEvidenceGroupCount != rhs.exactEvidenceGroupCount { return lhs.exactEvidenceGroupCount > rhs.exactEvidenceGroupCount }
        if lhs.automaticMaxConfidence != rhs.automaticMaxConfidence { return lhs.automaticMaxConfidence > rhs.automaticMaxConfidence }
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        return lhs.canonicalKey < rhs.canonicalKey
    }

    private func summary(_ term: MeetingGlossaryTerm) -> VocabularyTermSummary {
        .init(canonical: term.canonical, canonicalKey: term.canonicalKey, category: VocabularyCategory(rawValue: term.category) ?? .other, isPromoted: isPromoted(term), isRejected: term.rejectedAt != nil, aliases: term.userSpeechAliases.map { .init(value: $0, role: .speechAlias, origin: .user, active: true) } + term.userCanonicalizationAliases.map { .init(value: $0, role: .canonicalizationAlias, origin: .user, active: true) }, variants: term.variants, evidenceGroupCount: term.exactEvidenceGroupCount + term.correctionEvidenceGroupCount, sourceKinds: [], lastSeenAt: term.lastSeenAt)
    }

    private func hmac(_ raw: String, key: Data? = nil) -> String {
        guard let key = key ?? hmacKeys.first else { return "" }
        return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(raw.utf8), using: SymmetricKey(data: key)))
    }

    private func provenanceKeys(for raw: String) -> Set<String> {
        Set(hmacKeys.map { hmac(raw, key: $0) })
    }

    private func validSurface(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80 && !trimmed.contains(where: { $0.isNewline || String($0).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) })
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert(Self.normalizedKey($0)).inserted }
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(where: { Self.normalizedKey($0) == Self.normalizedKey(value) }) else { return }
        values.append(value)
    }

    nonisolated static func normalizedKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    nonisolated private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func isVocabularyToken(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let particles: Set<String> = ["은", "는", "이", "가", "을", "를", "에", "의", "와", "과", "도", "로", "으로", "에서", "에게", "만", "까지", "부터"]
        let endings = ["합니다", "했습니다", "한다", "했다", "됩니다", "습니다", "아요", "어요"]
        return token.count >= 2 && token.count <= 80
            && !token.contains(where: { $0.isWhitespace || $0.isNewline || String($0).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) })
            && !particles.contains(token)
            && !endings.contains(where: { token.hasSuffix($0) })
    }


    nonisolated static func replacementPairs(before: String, after: String) -> [(from: String, to: String)] {
        let old = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let new = after.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard old != new, !old.isEmpty, !new.isEmpty else { return [] }

        let oldKeys = old.map(normalizedKey)

        let newKeys = new.map(normalizedKey)
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = oldKeys[i] == newKeys[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [(from: String, to: String)] = []
        var i = 0
        var j = 0
        func appendBlock(_ oldBlock: ArraySlice<String>, _ newBlock: ArraySlice<String>) {
            guard oldBlock.count == 1, newBlock.count == 1,
                  let from = oldBlock.first, let to = newBlock.first,
                  normalizedKey(from) != normalizedKey(to),
                  from.count >= 2, to.count >= 2,
                  !from.allSatisfy(\.isNumber), !to.allSatisfy(\.isNumber),
                  !new.contains(where: { normalizedKey($0) == normalizedKey(from) }),
                  !old.contains(where: { normalizedKey($0) == normalizedKey(to) })
            else { return }
            result.append((from, to))
        }
        while i < old.count || j < new.count {
            let oldStart = i
            let newStart = j
            while i < old.count, j < new.count, oldKeys[i] != newKeys[j] {
                if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
            }
            appendBlock(old[oldStart..<i], new[newStart..<j])
            if i < old.count, j < new.count { i += 1; j += 1 }
            else { break }
        }
        if i < old.count || j < new.count {
            appendBlock(old[i..<old.count], new[j..<new.count])
        }
        return result
    }
}
