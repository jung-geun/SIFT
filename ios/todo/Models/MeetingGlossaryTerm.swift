import Foundation
import SwiftData

/// A user-specific vocabulary entry learned from meeting transcript edits and
/// AFM correction passes. Used to bias on-device transcription
/// (`AnalysisContext.contextualStrings`) and to hint the correction/summary
/// prompts toward the user's canonical spelling of names, projects, and terms.
///
/// Local-only: stored in `AppDataContainer.meetingSchema` (CloudKit `.none`),
/// alongside the transcripts it is derived from. All properties carry defaults so
/// the model stays lightweight and migration-safe.
@Model
final class MeetingGlossaryTerm {
    /// Correct spelling / display form, e.g. "쿠버네티스". Also the dedup key
    /// (case/whitespace-normalized) so repeated observations reinforce one entry.
    var canonical: String = ""
    /// Observed mis-recognitions that should map to `canonical`, e.g.
    /// ["쿠버네이트", "큐버네티스"].
    var variants: [String] = []
    /// Loose classification: person | project | acronym | term | product | other.
    var category: String = "other"
    /// How many times this term has been observed. Higher = more trusted.
    var frequency: Int = 0
    /// Provenance of the strongest signal seen: "editDiff" (user edit, high trust)
    /// or "correction" (AFM correction pass, candidate/low trust).
    var source: String = "correction"
    /// Set when a user edit undoes an AFM correction that produced this term —
    /// evidence the AFM was wrong. Reverted terms are demoted: never used for
    /// transcription biasing and dropped from prompt hints.
    var reverted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastSeenAt: Date = Date()
    /// Stable normalization key used for actor-owned deduplication.
    var canonicalKey: String = ""
    /// Explicit recognition hints. These never rewrite transcript text.
    var userSpeechAliases: [String] = []
    /// Explicit transcript rewrite aliases confirmed by the user.
    var userCanonicalizationAliases: [String] = []
    var confirmedLegacy: Bool = false
    var userConfirmedAt: Date?
    var rejectedAt: Date?
    var redirectCanonicalKey: String = ""
    var exactEvidenceGroupCount: Int = 0
    var highConfidenceExactEvidenceGroupCount: Int = 0
    var correctionEvidenceGroupCount: Int = 0
    var automaticMaxConfidence: Double = 0
    var observedSourceKinds: [String] = []
    var isDisplayUserEdited: Bool = false
    var isCategoryUserEdited: Bool = false

    init(
        canonical: String,
        variants: [String] = [],
        category: String = "other",
        frequency: Int = 1,
        source: String = "correction"
    ) {
        self.canonical = canonical
        self.variants = variants
        self.category = category
        self.frequency = frequency
        self.source = source
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.lastSeenAt = now
    }

    enum Source: String {
        /// User manually corrected a transcript segment — highest trust.
        case editDiff
        /// Derived from the AFM correction pass diff — candidate, needs
        /// corroboration before it biases transcription.
        case correction
        case manual
    }

    /// Whether this term is trusted enough to bias on-device transcription
    /// (`AnalysisContext.contextualStrings`). User edits qualify immediately;
    /// AFM-correction candidates must be corroborated (`corroborationThreshold`)
    /// and not reverted, to avoid an AFM mis-correction self-reinforcing.
    func isPromoted(corroborationThreshold: Int = 2) -> Bool {
        guard !reverted, !canonical.isEmpty else { return false }
        if source == Source.editDiff.rawValue || source == Source.manual.rawValue { return true }
        return frequency >= corroborationThreshold
    }
}
