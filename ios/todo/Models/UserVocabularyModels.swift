import Foundation
import SwiftData

@Model
final class VocabularyStoreMetadata {
    var storeKey: String = "userVocabulary"
    var schemaRepairVersion: Int = 0
    var hmacVerifier: String = ""
    var lastCompletedBackfillAt: Date?
    var lastCompletedBackfillExtractorVersion: Int = 0

    init() {}
}

@Model
final class VocabularySourceState {
    var sourceKey: String = ""
    var evidenceGroupKey: String = ""
    var sourceKindRaw: String = VocabularySourceKind.todo.rawValue
    var contentFingerprint: String = ""
    var extractorVersion: Int = 0
    var generation: UUID = UUID()
    var enrichmentVersion: Int = 0
    var enrichmentStatusRaw: String = VocabularyEnrichmentStatus.pending.rawValue
    var lastEnrichmentAttemptAt: Date?
    var enrichmentFailureCount: Int = 0
    var updatedAt: Date = Date()

    init() {}
}

@Model
final class VocabularyObservation {
    /// Evidence and spelling can be repaired independently of this durable row identity.
    var id: UUID = UUID()
    var canonicalKey: String = ""
    var canonicalDisplay: String = ""
    var sourceKey: String = ""
    var sourceGeneration: UUID = UUID()
    var evidenceGroupKey: String = ""
    var surfaceKey: String = ""
    var surfaceDisplay: String = ""
    var roleRaw: String = VocabularyObservationRole.canonical.rawValue
    var evidenceKindRaw: String = VocabularyEvidenceKind.exact.rawValue
    var categoryRaw: String = VocabularyCategory.other.rawValue
    var confidence: Double = 0
    var observedAt: Date = Date()

    init() {}
}

enum VocabularySourceKind: String, Codable, Sendable, CaseIterable {
    case email, todo, transcriptCorrection, transcriptEdit, manual
}

enum VocabularyObservationRole: String, Codable, Sendable, CaseIterable {
    case canonical, speechAlias, canonicalizationAlias, variant
}

enum VocabularyEvidenceKind: String, Codable, Sendable, CaseIterable {
    case exact, transcriptCorrection, modelProposal
}

enum VocabularyEnrichmentStatus: String, Codable, Sendable, CaseIterable {
    case notNeeded, pending, completed, failed
}

enum VocabularyCategory: String, Codable, Sendable, CaseIterable {
    case person, organization, project, product, acronym, technicalTerm, foreignWord, confusable, other
}

enum VocabularyTextFieldKind: String, Codable, Sendable, CaseIterable {
    case subject, body, notes, tags, senderDisplay, transcript
}

struct VocabularyTextField: Sendable, Hashable {
    let kind: VocabularyTextFieldKind
    let value: String

    nonisolated init(_ kind: VocabularyTextFieldKind, _ value: String) {
        self.kind = kind
        self.value = value
    }
}

struct VocabularySourceDocument: Sendable, Hashable {
    let source: VocabularySourceKind
    let stableID: String
    let evidenceGroupID: String
    let contentFingerprint: String
    let fields: [VocabularyTextField]

    nonisolated init(source: VocabularySourceKind, stableID: String, evidenceGroupID: String, contentFingerprint: String, fields: [VocabularyTextField]) {
        self.source = source
        self.stableID = stableID
        self.evidenceGroupID = evidenceGroupID
        self.contentFingerprint = contentFingerprint
        self.fields = fields
    }
}

struct VocabularyCandidate: Sendable, Hashable {
    let canonical: String
    let surface: String
    let role: VocabularyObservationRole
    let category: VocabularyCategory
    let confidence: Double
}

struct VocabularyCanonicalizationProposal: Sendable, Hashable {
    let candidateID: String
    let canonical: String
    let speechAlias: String?
    let category: VocabularyCategory
}

struct VocabularyEnrichmentRequest: Sendable, Hashable {
    struct Token: Sendable, Hashable {
        let sourceKey: String
        let contentFingerprint: String
        let extractorVersion: Int
        let generation: UUID
        let canonicalizationVersion: Int
    }

    let token: Token
    let candidates: [VocabularyCandidate]
    let context: String
}

enum VocabularyEnrichmentOutcome: Sendable, Equatable {
    case completed([VocabularyCanonicalizationProposal])
    case unavailable
    case failed
}

enum VocabularyAliasOrigin: String, Sendable, Hashable {
    case user, sourceSupported, modelProposal, misrecognition
}

struct VocabularyAliasSummary: Sendable, Hashable {
    let value: String
    let role: VocabularyObservationRole
    let origin: VocabularyAliasOrigin
    let active: Bool
}

struct VocabularyTermSummary: Sendable, Hashable {
    let canonical: String
    let canonicalKey: String
    let category: VocabularyCategory
    let isPromoted: Bool
    let isRejected: Bool
    let aliases: [VocabularyAliasSummary]
    let variants: [String]
    let evidenceGroupCount: Int
    let sourceKinds: [VocabularySourceKind]
    let lastSeenAt: Date
}

struct VocabularyTermDraft: Sendable, Hashable {
    var canonical: String
    var category: VocabularyCategory
    var speechAliases: [String]
    var canonicalizationAliases: [String]
    var variants: [String]

    init(canonical: String, category: VocabularyCategory = .other, speechAliases: [String] = [], canonicalizationAliases: [String] = [], variants: [String] = []) {
        self.canonical = canonical
        self.category = category
        self.speechAliases = speechAliases
        self.canonicalizationAliases = canonicalizationAliases
        self.variants = variants
    }
}

struct VocabularyCanonicalizationMapping: Sendable, Hashable {
    let alias: String
    let aliasKey: String
    let canonical: String
    let canonicalKey: String
    let origin: VocabularyAliasOrigin
}

struct UserVocabularySnapshot: Sendable, Hashable {
    let revisionHash: String
    let contextualStrings: [String]
    let protectedCanonicalPhrases: [String]
    let canonicalizationMappings: [VocabularyCanonicalizationMapping]
    let promptHint: String

    static let empty = UserVocabularySnapshot(revisionHash: "", contextualStrings: [], protectedCanonicalPhrases: [], canonicalizationMappings: [], promptHint: "")
}
