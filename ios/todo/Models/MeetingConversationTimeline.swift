import Foundation

/// A display projection only. Audio, transcript IDs and speaker IDs remain source-local.
struct MeetingConversationTimeline {
    struct Row: Identifiable, Equatable {
        struct ID: Hashable {
            let trackID: String
            let localID: String
        }
        let id: ID
        let localStartMs: Int64
        let localEndMs: Int64
        let startSample: Int64?
        let endSample: Int64?
        let text: String
        let speakerIDs: [String]
        var blocksSpeakerInheritance = false
        var evidenceSpeakerIDs: [String] = []
    }

    struct Entry {
        let id: String
        let startMs: Int64
        let endMs: Int64
        let text: String
        let speakerIDs: [String]
        var blocksSpeakerInheritance = false
        var evidenceSpeakerIDs: [String] = []
    }

    struct Source: Identifiable {
        let trackID: String
        /// nil means the track cannot be placed on this group's common media clock.
        let sessionStartSample: Int64?
        let entries: [Entry]
        var id: String { trackID }
    }

    struct UnalignedSource: Identifiable {
        let id: String
        let rows: [Row]
    }

    struct Turn: Identifiable, Equatable {
        var rows: [Row]
        var presentation: MeetingSpeakerContinuity.Presentation
        var id: Row.ID { rows[0].id }
        var localStartMs: Int64 { rows[0].localStartMs }
        var localEndMs: Int64 { rows.last?.localEndMs ?? rows[0].localEndMs }
        var startSample: Int64? { rows[0].startSample }
        var endSample: Int64? { rows.last?.endSample ?? rows[0].endSample }
        var text: String {
            rows.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    let rows: [Row]
    /// Deliberately not appended to `rows`: their position relative to other sources is unknown.
    let unalignedSources: [UnalignedSource]
    let speakerPresentation: [Row.ID: MeetingSpeakerContinuity.Presentation]

    static func groupTurns(_ rows: [Row], presentation: [Row.ID: MeetingSpeakerContinuity.Presentation]) -> [Turn] {
        var turns: [Turn] = []
        for row in rows {
            let itemPresentation = presentation[row.id]
                ?? MeetingSpeakerContinuity.Presentation(speakerIDs: row.speakerIDs, isInherited: false, startsTurn: true, kind: .speaker)
            if itemPresentation.startsTurn || turns.isEmpty || turns.last?.rows.first?.id.trackID != row.id.trackID {
                turns.append(Turn(rows: [row], presentation: itemPresentation))
            } else {
                let index = turns.count - 1
                let last = turns[index].presentation
                turns[index].presentation = MeetingSpeakerContinuity.Presentation(
                    speakerIDs: last.speakerIDs,
                    isInherited: last.isInherited && itemPresentation.isInherited,
                    startsTurn: true,
                    kind: last.kind
                )
                turns[index].rows.append(row)
            }
        }
        return turns
    }

    init(sources: [Source], preservesSourceEntryOrder: Bool = false) {
        var aligned: [Row] = []
        var unaligned: [UnalignedSource] = []
        for source in sources {
            let entries = source.entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let offset = source.sessionStartSample
            let hasCommonTime = offset.map { offset in
                offset >= 0 && offset <= MeetingMediaTimeline.maximumSamples && entries.allSatisfy {
                    $0.startMs >= 0 && $0.endMs > $0.startMs &&
                    $0.endMs <= (MeetingMediaTimeline.maximumSamples - offset) / Self.samplesPerMillisecond
                }
            } ?? false
            let projected = entries.map { entry in
                Row(id: Row.ID(trackID: source.trackID, localID: entry.id),
                    localStartMs: entry.startMs, localEndMs: entry.endMs,
                    startSample: hasCommonTime ? offset! + entry.startMs * Self.samplesPerMillisecond : nil,
                    endSample: hasCommonTime ? offset! + entry.endMs * Self.samplesPerMillisecond : nil,
                    text: entry.text, speakerIDs: entry.speakerIDs,
                    blocksSpeakerInheritance: entry.blocksSpeakerInheritance,
                    evidenceSpeakerIDs: entry.evidenceSpeakerIDs)
            }
            if hasCommonTime {
                aligned.append(contentsOf: projected)
            } else {
                unaligned.append(UnalignedSource(id: source.trackID, rows: preservesSourceEntryOrder ? projected : projected.sorted {
                    ($0.localStartMs, $0.localEndMs, $0.id.localID) < ($1.localStartMs, $1.localEndMs, $1.id.localID)
                }))
            }
        }
        // Sort by onset, not completion or arrival. Overlaps remain separate rows.
        // Sample precision preserves sub-millisecond source offsets at boundaries.
        rows = aligned.sorted {
            if $0.startSample != $1.startSample { return $0.startSample! < $1.startSample! }
            if $0.endSample != $1.endSample { return $0.endSample! < $1.endSample! }
            if $0.id.trackID != $1.id.trackID { return $0.id.trackID < $1.id.trackID }
            return $0.id.localID < $1.id.localID
        }
        unalignedSources = unaligned.sorted { $0.id < $1.id }
        var presentation = MeetingSpeakerContinuity.project(rows)
        for source in unalignedSources {
            presentation.merge(MeetingSpeakerContinuity.project(source.rows), uniquingKeysWith: { first, _ in first })
        }
        speakerPresentation = presentation
    }

    private static let samplesPerMillisecond = MeetingMediaTimeline.sampleRate / 1_000

    static func live(_ tracks: [MeetingLiveCaptureTrack]) -> Self {
        Self(sources: tracks.map { track in
            // Speech range IDs include the changing duration. Anchor display identity
            // to local onset instead, so partial text/finality updates do not churn rows.
            // A moved onset is a new turn; same-onset turns use a deterministic rank.
            var counts: [Int64: Int] = [:]
            let entries = track.liveTranscriptRows.sorted {
                ($0.startMs, $0.id) < ($1.startMs, $1.id)
            }.map { row in
                let rank = counts[row.startMs, default: 0]
                counts[row.startMs] = rank + 1
                return Entry(id: "\(row.startMs)#\(rank)", startMs: row.startMs, endMs: row.endMs,
                             text: row.text, speakerIDs: row.speakerIDs,
                             evidenceSpeakerIDs: row.evidenceSpeakerIDs)
            }
            return Source(trackID: track.meetingID, sessionStartSample: track.sessionStartSample, entries: entries)
        })
    }

    static func saved(_ tracks: [MeetingRecord], groupID: String) -> Self {
        Self(sources: tracks.map { track in
            Source(trackID: track.meetingID,
                   sessionStartSample: track.parentMeetingID == groupID ? track.conversationStartSample : nil,
                   entries: entries(for: track))
        })
    }

    static func individual(_ record: MeetingRecord) -> Self {
        // The detail renders validated current-ID order, which can differ from
        // lineage order after an edit at tied timestamps. Never move its rows.
        Self(sources: [Source(trackID: record.meetingID, sessionStartSample: nil, entries: entries(for: record))],
             preservesSourceEntryOrder: true)
    }

    private static func entries(for record: MeetingRecord) -> [Entry] {
        let payload = record.diarization
        let evidenceIndex = SpeakerEvidenceIndex(payload?.intervals ?? [])
        return (record.result?.segments ?? []).map { segment in
            let evidence = MeetingSpeakerAlignment.sampleRange(startMs: segment.startMs, endMs: segment.endMs)
                .map { evidenceIndex.speakers(start: $0.0, end: $0.1) } ?? []
            return Entry(id: segment.stableLineageID, startMs: segment.startMs, endMs: segment.endMs,
                         text: segment.text, speakerIDs: segment.speakerIDs,
                         blocksSpeakerInheritance: payload?.manualAssignments[segment.stableLineageID] != nil,
                         evidenceSpeakerIDs: evidence)
        }
    }

    /// Merge per-speaker ranges once: binary search remains correct for nested
    /// or out-of-order transcript ranges without rescanning every interval.
    private struct SpeakerEvidenceIndex {
        private let indexedSpeakers: [(id: String, ranges: [(start: Int64, end: Int64)])]

        init(_ intervals: [MeetingSpeakerInterval]) {
            let grouped = Dictionary(grouping: intervals, by: \.speakerID)
            indexedSpeakers = grouped.keys.sorted().map { id in
                let ordered = grouped[id]!.sorted { ($0.startSample, $0.endSample) < ($1.startSample, $1.endSample) }
                var merged: [(start: Int64, end: Int64)] = []
                for interval in ordered where interval.startSample < interval.endSample {
                    if let last = merged.indices.last, interval.startSample <= merged[last].end {
                        merged[last].end = max(merged[last].end, interval.endSample)
                    } else {
                        merged.append((interval.startSample, interval.endSample))
                    }
                }
                return (id, merged)
            }
        }

        func speakers(start: Int64, end: Int64) -> [String] {
            var result: [String] = []
            for speaker in indexedSpeakers {
                var lower = 0
                var upper = speaker.ranges.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if speaker.ranges[middle].end <= start { lower = middle + 1 }
                    else { upper = middle }
                }
                if lower < speaker.ranges.count, speaker.ranges[lower].start < end {
                    result.append(speaker.id)
                }
            }
            return result
        }
    }
}

/// Presentation only: never feeds attribution, editing, exports, or persisted evidence.
/// Matching source-local speakers bracket an unknown run into one displayed turn,
/// regardless of run length or uncertain interval evidence. Ten-second pauses,
/// manual assignments and nonidentical overlapping ranges remain hard boundaries.
enum MeetingSpeakerContinuity {
    struct Presentation: Equatable {
        enum Kind: Equatable { case speaker, unknown, mixed }
        let speakerIDs: [String]
        let isInherited: Bool
        let startsTurn: Bool
        let kind: Kind
    }

    // Presentation bound for grouping same-speaker speech and bridging brief undetected gaps.
    static let maximumUnknownContextMs: Int64 = 10_000
    static let maximumAdjacentGapMs: Int64 = 5_000
    static let maximumTurnGapMs: Int64 = 10_000
    static func project(_ rows: [MeetingConversationTimeline.Row]) -> [MeetingConversationTimeline.Row.ID: Presentation] {
        guard !rows.isEmpty else { return [:] }
        var blocked = Array(repeating: false, count: rows.count)
        var latestEnd: Int64?
        for (index, row) in rows.enumerated() {
            let start = row.startSample ?? row.localStartMs
            let end = row.endSample ?? row.localEndMs
            let nextStart = index + 1 < rows.count
                ? (rows[index + 1].startSample ?? rows[index + 1].localStartMs) : nil
            blocked[index] = row.blocksSpeakerInheritance || row.localStartMs < 0 || row.localEndMs <= row.localStartMs
                || latestEnd.map { start < $0 } == true || nextStart.map { $0 < end } == true
            latestEnd = max(latestEnd ?? end, end)
        }
        func adjacent(_ left: MeetingConversationTimeline.Row, _ right: MeetingConversationTimeline.Row) -> Bool {
            left.id.trackID == right.id.trackID && right.localStartMs >= left.localEndMs
                && right.localStartMs - left.localEndMs <= maximumAdjacentGapMs
        }
        func withinTurnGap(_ left: MeetingConversationTimeline.Row, _ right: MeetingConversationTimeline.Row) -> Bool {
            left.id.trackID == right.id.trackID && right.localStartMs >= left.localEndMs
                && right.localStartMs - left.localEndMs <= maximumTurnGapMs
        }
        // Resolve complete unknown runs before the conservative open-tail fallback.
        // Segment speaker IDs are the anchors; interval guesses remain unchanged.
        var bracketedSpeakers = Array<String?>(repeating: nil, count: rows.count)
        var runStart = 0
        while runStart < rows.count {
            guard rows[runStart].speakerIDs.isEmpty, !blocked[runStart] else {
                runStart += 1
                continue
            }
            var runEnd = runStart + 1
            while runEnd < rows.count, rows[runEnd].speakerIDs.isEmpty,
                  !blocked[runEnd], withinTurnGap(rows[runEnd - 1], rows[runEnd]) {
                runEnd += 1
            }
            if runStart > 0, runEnd < rows.count,
               !blocked[runStart - 1], !blocked[runEnd],
               withinTurnGap(rows[runStart - 1], rows[runStart]),
               withinTurnGap(rows[runEnd - 1], rows[runEnd]) {
                let before = Set(rows[runStart - 1].speakerIDs)
                let after = Set(rows[runEnd].speakerIDs)
                if before.count == 1, before == after, let speaker = before.first {
                    for index in runStart..<runEnd { bracketedSpeakers[index] = speaker }
                }
            }
            runStart = runEnd
        }
        // nil means the live tail has no following evidence yet; [] is an
        // explicit contradictory/overlap/manual boundary, never an open tail.
        var following = Array<[String]?>(repeating: nil, count: rows.count)
        var unknownRunEnd = rows.map(\.localEndMs)
        for index in rows.indices.reversed() where index + 1 < rows.count {
            let next = rows[index + 1]
            guard withinTurnGap(rows[index], next) else { continue }
            if blocked[index + 1] { following[index] = []; continue }
            if next.speakerIDs.isEmpty { unknownRunEnd[index] = unknownRunEnd[index + 1] }
            let ids = Array(Set(next.speakerIDs)).sorted()
            if !ids.isEmpty {
                following[index] = ids.count == 1 && next.evidenceSpeakerIDs.allSatisfy({ $0 == ids[0] }) ? ids : []
                continue
            }
            let evidence = Array(Set(next.evidenceSpeakerIDs)).sorted()
            if evidence.isEmpty { following[index] = following[index + 1] }
            else if let later = following[index + 1], later != evidence { following[index] = [] }
            else { following[index] = evidence }
        }
        var result: [MeetingConversationTimeline.Row.ID: Presentation] = [:]
        var anchor: (speaker: String, endMs: Int64)?
        var previous: MeetingConversationTimeline.Row?
        var previousIDs: [String] = []
        var previousKind: Presentation.Kind?
        for (index, row) in rows.enumerated() {
            let sameSource = previous?.id.trackID == row.id.trackID
            if (previous.map({ !withinTurnGap($0, row) }) ?? true) || blocked[index] { anchor = nil }
            var ids = Array(Set(row.speakerIDs)).sorted()
            let adjacentToPrevious = previous.map { adjacent($0, row) } ?? false
            var inherited = false
            let mixed = ids.isEmpty && Set(row.evidenceSpeakerIDs).count > 1 && bracketedSpeakers[index] == nil
            if let speaker = bracketedSpeakers[index] {
                ids = [speaker]
                inherited = true
            } else if ids.isEmpty, !blocked[index], !mixed, let known = anchor,
               row.localEndMs >= known.endMs,
               adjacentToPrevious,
               unknownRunEnd[index] - known.endMs <= maximumUnknownContextMs,
               row.evidenceSpeakerIDs.allSatisfy({ $0 == known.speaker }),
               following[index].map({ $0 == [known.speaker] }) ?? true {
                ids = [known.speaker]
                inherited = true
            }
            let kind: Presentation.Kind = mixed ? .mixed : (ids.isEmpty ? .unknown : .speaker)
            let gapExceeded = previous.map { row.localStartMs - $0.localEndMs > maximumTurnGapMs } ?? false
            // Edited segments can share an exact range while current-ID order
            // differs from lineage order. Keep their measured speaker heading
            // together without allowing overlapping unknowns to inherit it.
            let repeatsMeasuredSpeakerRange = blocked[index] && (previous.map {
                sameSource && !$0.blocksSpeakerInheritance && !row.blocksSpeakerInheritance
                    && row.localStartMs >= 0 && row.localEndMs > row.localStartMs
                    && row.localStartMs == $0.localStartMs && row.localEndMs == $0.localEndMs
                    && row.startSample == $0.startSample && row.endSample == $0.endSample
                    && !$0.speakerIDs.isEmpty && !ids.isEmpty && ids == previousIDs
            } ?? false)
            let startsTurn = previous == nil || !sameSource || (blocked[index] && !repeatsMeasuredSpeakerRange)
                || gapExceeded || ids != previousIDs || kind != previousKind
            result[row.id] = Presentation(speakerIDs: ids, isInherited: inherited, startsTurn: startsTurn, kind: kind)
            if !inherited {
                let compatibleAnchor = ids.count == 1 && !blocked[index]
                    && row.evidenceSpeakerIDs.allSatisfy({ $0 == ids[0] })
                anchor = compatibleAnchor ? (ids[0], row.localEndMs) : nil
            }
            previous = row
            previousIDs = ids
            previousKind = kind
        }
        return result
    }
}

extension MeetingRecord {
    /// Group capture/recovery co-persist kind, parent and the router's sample origin.
    /// A default zero on a legacy/mixed row is NOT evidence of a common origin.
    var conversationStartSample: Int64? {
        guard parentMeetingID != nil, let kind = audioTrackKind, kind != .legacyMixed,
              audioTrackStartSample >= 0, audioTrackStartSample <= MeetingMediaTimeline.maximumSamples else { return nil }
        return audioTrackStartSample
    }
}
