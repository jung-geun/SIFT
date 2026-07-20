import Foundation

/// Computes what the correction ("검수") pass changed, by comparing the raw
/// (pre-refinement) transcript to the current one. Drives the "AI 검수 결과" view
/// so the user can actually see which words the on-device model fixed.
///
/// Pure and deterministic — testable without AFM/MLX.
enum MeetingProofread {
    /// One inline diff token for display.
    enum Token: Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// A single segment the model corrected: original text, corrected text, and
    /// the word-level inline diff between them.
    struct SegmentCorrection: Identifiable, Equatable {
        let id: String
        let startMs: Int64
        let before: String
        let after: String
        let tokens: [Token]
    }

    enum InlinePresentation: Equatable {
        case hidden
        case unchanged(engineLabel: String)
        case changed(engineLabel: String, correctionsBySegmentID: [String: SegmentCorrection])
    }

    private struct TimingKey: Hashable {
        let startMs: Int64
        let endMs: Int64
    }

    private enum CorrectionMatch {
        case matched([SegmentCorrection])
        case ambiguousLegacy
    }

    static func corrections(raw: MeetingResult, current: MeetingResult) -> [SegmentCorrection] {
        switch matchCorrections(raw: raw, current: current) {
        case .matched(let corrections):
            return corrections
        case .ambiguousLegacy:
            return []
        }
    }

    static func inlinePresentation(
        raw: MeetingResult?,
        current: MeetingResult,
        engineLabel: String,
        language: AppLanguage
    ) -> InlinePresentation {
        let stored = engineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !stored.isEmpty else { return .hidden }
        let displayLabel: String
        if let source = MeetingRefinementEngine.Source(rawValue: stored) {
            displayLabel = source.displayName(language: language)
        } else {
            switch stored {
            case "Apple Intelligence 온디바이스":
                displayLabel = MeetingRefinementEngine.Source.appleIntelligence.displayName(language: language)
            case "온디바이스 LLM(Qwen)":
                displayLabel = MeetingRefinementEngine.Source.qwen.displayName(language: language)
            case "사용자 단어장":
                displayLabel = MeetingRefinementEngine.Source.userVocabulary.displayName(language: language)
            default:
                displayLabel = AppLanguage.localized(
                    "meeting.engine.unknown",
                    defaultValue: language == .english ? "Unknown Engine" : "알 수 없는 엔진",
                    language: language,
                    comment: "Unknown legacy meeting engine provenance"
                )
            }
        }

        if current.transcriptRevision == raw.transcriptRevision {
            return current.segments == raw.segments
                ? .unchanged(engineLabel: displayLabel)
                : .hidden
        }
        guard current.transcriptRevision == raw.transcriptRevision + 1 else { return .hidden }

        switch matchCorrections(raw: raw, current: current) {
        case .ambiguousLegacy:
            return .hidden
        case .matched(let corrections):
            guard !corrections.isEmpty else { return .unchanged(engineLabel: displayLabel) }
            var correctionsBySegmentID = [String: SegmentCorrection]()
            correctionsBySegmentID.reserveCapacity(corrections.count)
            for correction in corrections {
                correctionsBySegmentID[correction.id] = correction
            }
            return .changed(
                engineLabel: displayLabel,
                correctionsBySegmentID: correctionsBySegmentID
            )
        }
    }

    private static func matchCorrections(raw: MeetingResult, current: MeetingResult) -> CorrectionMatch {
        var rawByLineage = [String: MeetingSegment]()
        for segment in raw.segments {
            guard rawByLineage.updateValue(segment, forKey: segment.stableLineageID) == nil else {
                return .ambiguousLegacy
            }
        }

        var matches = [(current: MeetingSegment, raw: MeetingSegment)]()
        var matchedRawLineages = Set<String>()
        for segment in current.segments where segment.lineageID != nil {
            guard let rawSegment = rawByLineage[segment.stableLineageID],
                  rawSegment.startMs == segment.startMs,
                  rawSegment.endMs == segment.endMs
            else { continue }
            matches.append((segment, rawSegment))
            matchedRawLineages.insert(rawSegment.stableLineageID)
        }

        let unmatchedRaw = raw.segments.filter {
            $0.lineageID == nil && !matchedRawLineages.contains($0.stableLineageID)
        }
        let legacyCurrent = current.segments.filter { $0.lineageID == nil }
        let rawGroups = Dictionary(grouping: unmatchedRaw) {
            TimingKey(startMs: $0.startMs, endMs: $0.endMs)
        }
        let currentGroups = Dictionary(grouping: legacyCurrent) {
            TimingKey(startMs: $0.startMs, endMs: $0.endMs)
        }
        if rawGroups.values.contains(where: { $0.count > 1 }) ||
            currentGroups.values.contains(where: { $0.count > 1 }) {
            return .ambiguousLegacy
        }
        for (key, currentGroup) in currentGroups {
            guard let currentSegment = currentGroup.first,
                  let rawSegment = rawGroups[key]?.first
            else { continue }
            matches.append((currentSegment, rawSegment))
        }

        let corrections = matches
            .sorted {
                ($0.current.startMs, $0.current.endMs, $0.current.id) <
                ($1.current.startMs, $1.current.endMs, $1.current.id)
            }
            .compactMap { pair -> SegmentCorrection? in
                guard pair.raw.text != pair.current.text else { return nil }
                let tokens = diffTokens(before: pair.raw.text, after: pair.current.text)
                let hasVisibleChange = tokens.contains {
                    switch $0 {
                    case .same: false
                    case .removed, .added: true
                    }
                }
                guard hasVisibleChange else { return nil }
                return SegmentCorrection(
                    id: pair.current.id,
                    startMs: pair.current.startMs,
                    before: pair.raw.text,
                    after: pair.current.text,
                    tokens: tokens
                )
            }
        return .matched(corrections)
    }

    /// Word-level diff via LCS: shared words are `.same`, words only in the
    /// original are `.removed`, words only in the corrected text are `.added`.
    /// Emitted in reading order (removed before added within a change block).
    static func diffTokens(before: String, after: String) -> [Token] {
        let beforeWords = before.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let afterWords = after.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let lcs = longestCommonSubsequence(beforeWords, afterWords)

        var tokens = [Token]()
        var i = 0, j = 0, k = 0
        while i < beforeWords.count || j < afterWords.count {
            let anchor = k < lcs.count ? lcs[k] : nil
            let atBefore = anchor != nil && i < beforeWords.count && beforeWords[i] == anchor
            let atAfter = anchor != nil && j < afterWords.count && afterWords[j] == anchor
            if atBefore, atAfter {
                tokens.append(.same(beforeWords[i]))
                i += 1; j += 1; k += 1
            } else if i < beforeWords.count, !atBefore {
                tokens.append(.removed(beforeWords[i])); i += 1
            } else if j < afterWords.count {
                tokens.append(.added(afterWords[j])); j += 1
            } else {
                break
            }
        }
        return tokens
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for x in stride(from: n - 1, through: 0, by: -1) {
            for y in stride(from: m - 1, through: 0, by: -1) {
                dp[x][y] = a[x] == b[y] ? dp[x + 1][y + 1] + 1 : max(dp[x + 1][y], dp[x][y + 1])
            }
        }
        var result = [String]()
        var x = 0, y = 0
        while x < n, y < m {
            if a[x] == b[y] {
                result.append(a[x]); x += 1; y += 1
            } else if dp[x + 1][y] >= dp[x][y + 1] {
                x += 1
            } else {
                y += 1
            }
        }
        return result
    }
}
