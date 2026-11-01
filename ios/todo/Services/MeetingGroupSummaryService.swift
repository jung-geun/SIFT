import CryptoKit
import Foundation
import SwiftData

/// Synthesizes independent source transcripts without giving the parent an audio,
/// transcript, or speaker namespace. Provider input IDs are only an in-memory map.
@MainActor
enum MeetingGroupSummaryService {
    enum Failure: LocalizedError, Equatable {
        case notReady, emptyTranscript, invalidAnalysis, superseded, summaryLanguageRequired

        var errorDescription: String? {
            switch self {
            case .notReady:
                return AppLanguage.localized("meeting.group.summary.notReady", defaultValue: "Wait for every source to finish processing before summarizing the meeting.", language: .current, comment: "Group summary requires completed sources.")
            case .emptyTranscript:
                return AppLanguage.localized("meeting.group.summary.empty", defaultValue: "There is no transcript to summarize.", language: .current, comment: "Group summary has no transcript evidence.")
            case .invalidAnalysis:
                return AppLanguage.localized("meeting.group.summary.invalid", defaultValue: "No summary was produced. Your previous summary has been kept.", language: .current, comment: "Group summary provider returned no usable analysis.")
            case .summaryLanguageRequired:
                return AppLanguage.localized("meeting.group.summary.languageRequired", defaultValue: "Choose a summary language for this multilingual meeting.", language: .current, comment: "Mixed automatic source languages require an explicit summary language.")
            case .superseded:
                return AppLanguage.localized("meeting.error.changedDuringSummary", defaultValue: "The meeting changed during processing. Please try again.", language: .current, comment: "Meeting processing lost a race to an edit or deletion.")
            }
        }
    }

    struct Request {
        let meetingID: String
        let result: MeetingResult
        let citationSources: [String: MeetingSummaryCitation]
        let sourceLanguageTag: String
        let sourceLanguageTags: [String]
        let summaryLanguageTag: String
        let format: MeetingSummaryFormat
        let customInstructions: String
        let language: AppLanguage
    }

    struct Dependencies {
        let analyze: (Request) async throws -> MeetingAnalysisEngine.Outcome
        let save: (ModelContext) throws -> Void

        static var live: Self {
            Self(analyze: { request in
                try await MeetingAnalysisEngine().analyze(
                    meetingID: request.meetingID, result: request.result,
                    sourceLanguageTag: request.sourceLanguageTag,
                    summaryLanguageTag: request.summaryLanguageTag, language: request.language,
                    summaryFormat: request.format, customInstructions: request.customInstructions,
                    citationSources: request.citationSources,
                    sourceLanguageTags: request.sourceLanguageTags
                )
            }, save: { try $0.save() })
        }

        static func summary(model: MeetingSummaryModel) -> Self {
            Self(analyze: { request in
                if let tier = model.openAITier {
                    return try await MeetingAnalysisEngine().analyzeWithOpenAI(
                        meetingID: request.meetingID, result: request.result,
                        sourceLanguageTag: request.sourceLanguageTag,
                        summaryLanguageTag: request.summaryLanguageTag, language: request.language,
                        summaryFormat: request.format, customInstructions: request.customInstructions,
                        citationSources: request.citationSources, sourceLanguageTags: request.sourceLanguageTags,
                        tier: tier)
                }
                return try await MeetingAnalysisEngine().analyzeWithAppleIntelligence(
                    meetingID: request.meetingID, result: request.result,
                    sourceLanguageTag: request.sourceLanguageTag,
                    summaryLanguageTag: request.summaryLanguageTag, language: request.language,
                    summaryFormat: request.format, customInstructions: request.customInstructions,
                    citationSources: request.citationSources, sourceLanguageTags: request.sourceLanguageTags)
            }, save: { try $0.save() })
        }
    }

    /// False while any source is recording, transcribing, or postprocessing. A
    /// failed source is not silently omitted from a supposedly whole-group pass.
    static func canGenerate(parent: MeetingRecord, in context: ModelContext) throws -> Bool {
        let tracks = try MeetingAudioTrackStore.tracks(for: parent, in: context)
        return !tracks.isEmpty && tracks.allSatisfy { $0.status == .ready && $0.result != nil }
            && tracks.contains { $0.result?.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true }
    }

    /// Includes all contributing transcript bytes and source alignment, not just
    /// revision counters: edits, source replacement, order and language changes
    /// invalidate even if a caller forgot to increment a revision.
    static func sourceFingerprint(parent: MeetingRecord, in context: ModelContext) throws -> String {
        try sourceFingerprint(parent: parent, tracks: MeetingAudioTrackStore.tracks(for: parent, in: context))
    }

    enum SummaryEvidenceValidity: Equatable {
        case current, unverifiable, invalid
    }

    /// Output settings can become stale without making the saved evidence false.
    /// Legacy full-only hashes cannot prove source freshness after settings edits:
    /// retain their display, but never authorize import through isSummaryCurrent.
    static func summaryEvidenceValidity(parent: MeetingRecord, in context: ModelContext) throws -> SummaryEvidenceValidity {
        let tracks = try MeetingAudioTrackStore.tracks(for: parent, in: context)
        guard let result = parent.result else { return .unverifiable }
        let stored = result.summarySourceFingerprint?.split(separator: ":", omittingEmptySubsequences: false)
        let expected = try fingerprintDigests(parent: parent, tracks: tracks)
        let versioned = stored?.count == 3 && stored?.first == "v2"
        if versioned, stored?[1] != Substring(expected.source) { return .invalid }
        let allowed = qualifiedCitations(tracks: tracks)
        let items = result.summarySections?.flatMap(\.items) ?? []
        if items.flatMap(\.citations).contains(where: { !allowed.contains($0) }) { return .invalid }
        guard !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !items.isEmpty, items.allSatisfy({ !$0.citations.isEmpty }) else {
            return versioned ? .invalid : .unverifiable
        }
        if versioned || result.summarySourceFingerprint == expected.full { return .current }
        return .unverifiable
    }

    static func isSummaryCurrent(parent: MeetingRecord, in context: ModelContext) throws -> Bool {
        let tracks = try MeetingAudioTrackStore.tracks(for: parent, in: context)
        guard let result = parent.result, !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sections = result.summarySections, sections.contains(where: { !$0.items.isEmpty }) else { return false }
        let expected = try fingerprintDigests(parent: parent, tracks: tracks)
        guard result.summarySourceFingerprint == "v2:\(expected.source):\(expected.full)"
                || result.summarySourceFingerprint == expected.full else { return false }
        let citations = qualifiedCitations(tracks: tracks)
        return sections.flatMap(\.items).allSatisfy { item in
            !item.citations.isEmpty && item.citations.allSatisfy(citations.contains)
        }
    }

    private static func qualifiedCitations(tracks: [MeetingRecord]) -> Set<MeetingSummaryCitation> {
        Set(tracks.flatMap { track in
            (track.result?.segments ?? []).map {
                MeetingSummaryCitation(trackID: track.meetingID, segmentID: $0.id, transcriptRevision: track.transcriptRevision)
            }
        })
    }

    /// Explicit regeneration always runs, even for a current summary. Automatic
    /// callers can check isSummaryCurrent first. No mutation occurs before the
    /// final fenced, rollback-capable save; cancellation preserves prior analysis.
    @discardableResult
    static func generate(
        parent: MeetingRecord, in context: ModelContext, language: AppLanguage = .current,
        dependencies: Dependencies? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        let tracks = try MeetingAudioTrackStore.tracks(for: parent, in: context)
        guard tracks.allSatisfy({ $0.status == .ready && $0.result != nil }) else { throw Failure.notReady }
        let snapshot = Snapshot(parent: parent, tracks: tracks)
        let fingerprint = try sourceFingerprint(parent: parent, tracks: tracks)
        let request = try makeRequest(parent: parent, tracks: tracks, language: language)
        let dependencies = dependencies ?? .live
        let outcome = try await dependencies.analyze(request)
        try requireCurrent(parent: parent, snapshot: snapshot, in: context)
        let allowed = Set(request.citationSources.values)
        guard outcome.summaryKind == .generated, let sections = outcome.result.summarySections,
              !sections.isEmpty,
              sections.contains(where: { !$0.items.isEmpty }),
              sections.flatMap(\.items).allSatisfy({
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.citations.isEmpty && $0.citations.allSatisfy(allowed.contains)
              }) else { throw Failure.invalidAnalysis }
        var result = parent.result ?? MeetingResult()
        let generatedTitle = outcome.result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !generatedTitle.isEmpty { result.title = generatedTitle }
        result.summarySections = sections
        result.summarySourceFingerprint = fingerprint
        result.summary = sections.flatMap(\.items).map(\.text).joined(separator: "\n")
        result.decisions = outcome.result.decisions
        result.unresolvedQuestions = outcome.result.unresolvedQuestions
        // MeetingActionDraft has no track namespace. Parent drafts would make
        // same-ID source segments ambiguous; actionable drafts remain child-owned.
        // Group action prose is still available in the cited structured sections.
        result.actionDrafts = []
        result.segments = []
        try outcome.authorizationCheck?()
        try MeetingRecordCommitter.persist(record: parent, save: { try dependencies.save(context) }) {
            try parent.update(result: result, status: .ready)
            parent.summaryKindRaw = outcome.summaryKind.rawValue
            parent.summaryEngineLabel = outcome.engineSource?.rawValue ?? outcome.engineLabel
            if case .rules(let reason) = outcome.executionPath {
                parent.summaryFallbackReasonRaw = reason.rawValue
            } else {
                parent.summaryFallbackReasonRaw = nil
            }
            parent.summaryResultLanguageTag = outcome.summaryKind == .generated ? request.summaryLanguageTag : request.sourceLanguageTag
        }
        return true
    }

    private struct Snapshot {
        struct Row {
            let identity: PersistentIdentifier
            let state: MeetingRecord.PersistenceSnapshot
        }
        let parent: Row
        let tracks: [String: Row]

        init(parent: MeetingRecord, tracks: [MeetingRecord]) {
            self.parent = Row(identity: parent.persistentModelID, state: parent.persistenceSnapshot())
            self.tracks = Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.meetingID, Row(identity: $0.persistentModelID, state: $0.persistenceSnapshot()))
            })
        }
    }

    private static func requireCurrent(parent: MeetingRecord, snapshot: Snapshot, in context: ModelContext) throws {
        try Task.checkCancellation()
        // Check attachment before touching fault-backed persisted attributes.
        guard parent.modelContext === context, !parent.isDeleted else { throw Failure.superseded }
        let parentID = parent.meetingID
        guard let savedParent = try context.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.meetingID == parentID }
        )).first,
              savedParent.persistentModelID == snapshot.parent.identity,
              savedParent.persistenceSnapshot() == snapshot.parent.state,
              parent.persistenceSnapshot() == snapshot.parent.state else { throw Failure.superseded }
        let tracks: [MeetingRecord]
        do { tracks = try MeetingAudioTrackStore.tracks(for: savedParent, in: context) }
        catch { throw Failure.superseded }
        guard tracks.count == snapshot.tracks.count, tracks.allSatisfy({ track in
            guard let before = snapshot.tracks[track.meetingID] else { return false }
            return before.identity == track.persistentModelID && before.state == track.persistenceSnapshot()
        }) else { throw Failure.superseded }
    }

    private struct Fingerprint: Encodable {
        struct Source: Encodable {
            let id: String
            let kind: String?
            let label: String?
            let startSample: Int64
            let commonStartSample: Int64?
            let revision: Int
            let segments: [MeetingSegment]
            let sourceLanguage: String
            let diarization: Data?
        }
        let version: Int
        let parentID: String
        let declaredOrder: [String]
        let sourceLanguage: String
        let automaticLanguageDetection: Bool
        let summaryLanguage: String
        let format: String
        let customInstructions: String
        let sources: [Source]
    }

    private struct SourceEvidenceFingerprint: Encodable {
        let version: Int
        let parentID: String
        let declaredOrder: [String]
        let sources: [Fingerprint.Source]
    }

    private static func sourceFingerprint(parent: MeetingRecord, tracks: [MeetingRecord]) throws -> String {
        let digests = try fingerprintDigests(parent: parent, tracks: tracks)
        return "v2:\(digests.source):\(digests.full)"
    }

    private static func fingerprintDigests(parent: MeetingRecord, tracks: [MeetingRecord]) throws -> (source: String, full: String) {
        let value = Fingerprint(
            version: 1, parentID: parent.meetingID, declaredOrder: parent.audioTrackIDs,
            sourceLanguage: parent.languageTag, automaticLanguageDetection: parent.automaticLanguageDetection,
            summaryLanguage: parent.summaryLanguageTag, format: parent.summaryFormat.rawValue,
            customInstructions: parent.summaryCustomInstructions,
            sources: tracks.map { track in
                Fingerprint.Source(id: track.meetingID, kind: track.audioTrackKindRaw,
                    label: track.audioTrackSourceLabel, startSample: track.audioTrackStartSample,
                    commonStartSample: track.conversationStartSample,
                    revision: track.transcriptRevision, segments: track.result?.segments ?? [],
                    sourceLanguage: track.processingSourceLanguageTag, diarization: track.diarizationData)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let source = SourceEvidenceFingerprint(version: 2, parentID: value.parentID,
            declaredOrder: value.declaredOrder, sources: value.sources)
        let sourceDigest = SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
        let fullDigest = SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
        return (sourceDigest, fullDigest)
    }

    private static func makeRequest(parent: MeetingRecord, tracks: [MeetingRecord], language: AppLanguage) throws -> Request {
        var segments: [MeetingSegment] = []
        var citations: [String: MeetingSummaryCitation] = [:]
        var contributingLanguages = Set<String>()
        for (trackIndex, track) in tracks.enumerated() {
            guard let result = track.result else { throw Failure.notReady }
            for segment in result.segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contributingLanguages.insert(track.processingSourceLanguageTag)
                let projectionID = "source-\(trackIndex + 1)-segment-\(segments.count + 1)"
                let speaker = segment.speakerIDs.isEmpty ? "unknown" : segment.speakerIDs.joined(separator: ", ")
                let clock: String
                let samplesPerMillisecond = MeetingMediaTimeline.sampleRate / 1_000
                if let start = track.conversationStartSample,
                   segment.endMs <= (MeetingMediaTimeline.maximumSamples - start) / samplesPerMillisecond {
                    clock = "common-clock start sample \(start + segment.startMs * samplesPerMillisecond) at \(MeetingMediaTimeline.sampleRate) Hz"
                } else {
                    clock = "source-local time \(segment.startMs) ms; alignment to other sources is UNKNOWN"
                }
                let text = "[Source \(trackIndex + 1): \(track.audioTrackDisplayName); source language: \(track.processingSourceLanguageTag); speaker identity local to this source: \(speaker); \(clock)] \(segment.text)"
                // Sequential input positions are NOT a claimed common clock.
                let position = Int64(segments.count) * 2
                segments.append(MeetingSegment(id: projectionID, startMs: position, endMs: position + 1, text: text))
                citations[projectionID] = MeetingSummaryCitation(trackID: track.meetingID, segmentID: segment.id,
                                                               transcriptRevision: result.transcriptRevision)
            }
        }
        guard !segments.isEmpty else { throw Failure.emptyTranscript }
        // Silence has no language evidence. Its record still participates in
        // readiness, snapshots and fingerprints, but cannot authorize or veto
        // language capability for another source's actual transcript.
        let sourceLanguages = contributingLanguages.sorted()
        let commonLanguages = Set(sourceLanguages.map { tag in
            let locale = Locale(identifier: tag).language
            let code = locale.languageCode?.identifier ?? tag
            return locale.script.map { "\(code)-\($0.identifier)" } ?? code
        })
        // A shared language/script across regional aliases is a prompt descriptor
        // only. Every concrete child tag is still capability-checked.
        let sourceLanguage = commonLanguages.count == 1 ? commonLanguages.first! : "mul"
        let summaryLanguage = MeetingSummaryLanguages.requestedLanguageTag(
            sourceLanguageTag: parent.automaticLanguageDetection ? sourceLanguage : parent.languageTag,
            savedSummaryLanguageTag: parent.summaryLanguageTag)
        guard !["mul", "und", "zxx", ""].contains(summaryLanguage.lowercased()) else {
            throw Failure.summaryLanguageRequired
        }
        return Request(meetingID: parent.meetingID,
                       result: MeetingResult(title: parent.result?.title ?? "", segments: segments),
                       citationSources: citations, sourceLanguageTag: sourceLanguage,
                       sourceLanguageTags: sourceLanguages, summaryLanguageTag: summaryLanguage,
                       format: parent.summaryFormat, customInstructions: parent.summaryCustomInstructions, language: language)
    }
}
