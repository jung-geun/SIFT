import Foundation

/// Aligns actual Apple Speech timed text runs with independent speaker activity.
/// All comparisons use the canonical 16 kHz sample clock; half-open interval
/// endpoints touching one another do not count as simultaneous activity.
nonisolated enum MeetingSpeakerAlignment {
    static let samplesPerMillisecond: Int64 = 16

    static func assign(
        runs: [MeetingTimedTextRun],
        intervals: [MeetingSpeakerInterval],
        coveredThroughSample: Int64
    ) -> [[String]] {
        let ordered = intervals.sorted {
            ($0.startSample, $0.endSample, $0.speakerID) <
                ($1.startSample, $1.endSample, $1.speakerID)
        }
        let indexedRuns = runs.enumerated().sorted {
            ($0.element.startMs, $0.element.endMs, $0.offset) <
                ($1.element.startMs, $1.element.endMs, $1.offset)
        }
        var answer = Array(repeating: [String](), count: runs.count)
        var cursor = 0
        var active = [MeetingSpeakerInterval]()
        for (index, run) in indexedRuns {
            guard let (start, end) = sampleRange(startMs: run.startMs, endMs: run.endMs) else { continue }
            // A closed speaker interval is not evidence for the unprocessed suffix.
            guard end <= coveredThroughSample else { continue }
            active.removeAll { $0.endSample <= start }
            while cursor < ordered.count, ordered[cursor].startSample < end {
                active.append(ordered[cursor])
                cursor += 1
            }
            answer[index] = speakerIDs(start: start, end: end, intervals: active)
        }
        return answer
    }

    /// Segments without word timing cannot be split, so any sequential second
    /// speaker (at least 200 ms inside the segment) makes the label unknown.
    static func assignSegment(
        startMs: Int64,
        endMs: Int64,
        intervals: [MeetingSpeakerInterval],
        coveredThroughSample: Int64
    ) -> [String] {
        guard let (start, end) = sampleRange(startMs: startMs, endMs: endMs),
              end <= coveredThroughSample else { return [] }
        let contributing = intervals.filter { $0.startSample < end && $0.endSample > start }
        var overlaps: [String: Int64] = [:]
        for interval in contributing {
            overlaps[interval.speakerID, default: 0] += min(end, interval.endSample) - max(start, interval.startSample)
        }
        let present = overlaps.filter { $0.value >= 200 * samplesPerMillisecond || $0.value > (end - start) / 2 }
        if present.count == 1 { return speakerIDs(start: start, end: end, intervals: contributing) }
        guard present.count > 1 else { return [] }
        let simultaneous = speakerIDs(start: start, end: end, intervals: contributing)
        return simultaneous.count > 1 && Set(simultaneous) == Set(present.keys) ? simultaneous : []
    }

    /// Live-only attribution from the processed prefix of an unsplittable entry.
    /// Silence does not dilute a unique speaker's evidence, but at least 200 ms
    /// of actual activity is required. Sequential qualifying speakers remain
    /// unknown: without word timing there is no honest text boundary to split.
    static func assignLiveSegment(
        startMs: Int64,
        endMs: Int64,
        intervals: [MeetingSpeakerInterval],
        coveredThroughSample: Int64
    ) -> [String] {
        guard let (start, segmentEnd) = sampleRange(startMs: startMs, endMs: endMs) else { return [] }
        let end = min(segmentEnd, coveredThroughSample)
        guard end > start else { return [] }
        var overlaps: [String: Int64] = [:]
        for interval in intervals {
            let amount = min(end, interval.endSample) - max(start, interval.startSample)
            if amount > 0 { overlaps[interval.speakerID, default: 0] += amount }
        }
        let present = overlaps.filter { $0.value >= 200 * samplesPerMillisecond }
        if present.count == 1 { return Array(present.keys) }
        guard present.count > 1 else { return [] }
        let simultaneous = speakerIDs(start: start, end: end, intervals: intervals)
        return simultaneous.count > 1 && Set(simultaneous) == Set(present.keys) ? simultaneous : []
    }

    /// Consecutive runs with identical evidence form one turn. Unknown words
    /// remain unknown rather than inheriting a neighbour's label; untimed text
    /// stays adjacent and every boundary still comes from a timed run.
    static func turns(
        textLength: Int,
        startMs: Int64,
        endMs: Int64,
        runs: [MeetingTimedTextRun],
        labels: [[String]]
    ) -> [MeetingSpeakerTextTurn] {
        precondition(runs.count == labels.count)
        guard !runs.isEmpty else {
            return [MeetingSpeakerTextTurn(utf16Start: 0, utf16End: textLength, startMs: startMs, endMs: endMs, speakerIDs: [], runs: [])]
        }
        var groups: [(firstRun: Int, label: [String], runs: [MeetingTimedTextRun])] = []
        for (index, run) in runs.enumerated() {
            let label = labels[index]
            if let last = groups.indices.last, groups[last].label == label {
                groups[last].runs.append(run)
            } else {
                groups.append((index, label, [run]))
            }
        }
        return groups.enumerated().map { position, group in
            let next = position + 1 < groups.count ? runs[groups[position + 1].firstRun] : nil
            return MeetingSpeakerTextTurn(
                utf16Start: position == 0 ? 0 : runs[group.firstRun].utf16Offset,
                utf16End: next?.utf16Offset ?? textLength,
                startMs: position == 0 ? startMs : runs[group.firstRun].startMs,
                endMs: next?.startMs ?? endMs,
                speakerIDs: group.label,
                runs: group.runs
            )
        }
    }

    static func sampleRange(startMs: Int64, endMs: Int64) -> (Int64, Int64)? {
        guard startMs >= 0, endMs > startMs,
              endMs <= Int64.max / samplesPerMillisecond else { return nil }
        return (startMs * samplesPerMillisecond, endMs * samplesPerMillisecond)
    }

    private static func speakerIDs(
        start: Int64,
        end: Int64,
        intervals: [MeetingSpeakerInterval]
    ) -> [String] {
        let length = end - start
        var overlaps: [String: Int64] = [:]
        let contributing = intervals.filter { $0.startSample < end && $0.endSample > start }
        for interval in contributing {
            let amount = min(end, interval.endSample) - max(start, interval.startSample)
            if amount > 0 { overlaps[interval.speakerID, default: 0] += amount }
        }
        let substantial = overlaps.filter { $0.value * 2 >= length }.map(\.key).sorted()
        // Joint activity must reach min(100 ms, half the run).
        let jointMinimum = min(100 * samplesPerMillisecond, (length + 1) / 2)
        if substantial.count > 1 {
            var simultaneous = Set<String>()
            for left in 0..<substantial.count {
                for right in (left + 1)..<substantial.count {
                    var joint: Int64 = 0
                    for a in contributing where a.speakerID == substantial[left] {
                        for b in contributing where b.speakerID == substantial[right] {
                            joint += max(0, min(end, a.endSample, b.endSample) -
                                max(start, a.startSample, b.startSample))
                        }
                    }
                    if joint >= jointMinimum {
                        simultaneous.insert(substantial[left])
                        simultaneous.insert(substantial[right])
                    }
                }
            }
            if !simultaneous.isEmpty { return simultaneous.sorted() }
        }
        let ranked = overlaps.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let first = ranked.first, first.value * 2 > length,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= 10 * samplesPerMillisecond
        else { return [] }
        return [first.key]
    }
}

/// A display or split unit of one transcript segment. Offsets address the
/// original segment text; `runs` keep their original offsets.
nonisolated struct MeetingSpeakerTextTurn: Equatable, Sendable {
    let utf16Start: Int
    let utf16End: Int
    let startMs: Int64
    let endMs: Int64
    let speakerIDs: [String]
    let runs: [MeetingTimedTextRun]
}

/// Keeps a speaker number stable when a new pass re-detects the same person.
nonisolated enum MeetingSpeakerIdentityMatcher {
    static let minimumAgreement = 0.6
    static let minimumVoiceCosine = 0.75
    static let minimumVoiceMargin = 0.10

    /// Returns `new speaker ID -> reference speaker ID` for accepted matches only.
    /// Strong mutual voice bests claim identities first. Remaining speakers use
    /// maximum-intersection, one-to-one timing with ordinal tie-breaks, while
    /// contradictory valid voice still vetoes a temporal candidate.
    static func match(
        new newIntervals: [MeetingSpeakerInterval],
        reference referenceIntervals: [MeetingSpeakerInterval],
        referenceOrdinals: [String: Int],
        voiceEvidence: MeetingSpeakerVoiceEvidence? = nil
    ) -> [String: String] {
        let newSolo = soloActivity(newIntervals)
        let referenceSolo = soloActivity(referenceIntervals)
        let newIDs = firstAppearanceOrder(newIntervals).filter { newSolo[$0] != nil }
        let referenceIDs = referenceSolo.keys.sorted {
            (referenceOrdinals[$0] ?? Int.max, $0) < (referenceOrdinals[$1] ?? Int.max, $1)
        }
        guard !newIDs.isEmpty, !referenceIDs.isEmpty,
              newIDs.count <= 16, referenceIDs.count <= 16 else { return [:] }

        let voice = voiceSimilarities(newIDs: newIDs, referenceIDs: referenceIDs, evidence: voiceEvidence)
        var mapping: [String: String] = [:]
        var matchedRows = 0
        var matchedReferences = 0
        // Margins use the entire matrix: a consumed best must not promote a
        // runner-up, and timing must not override a strong identity match.
        if let voice {
            for row in newIDs.indices {
                for column in referenceIDs.indices {
                    guard let cosine = voice[row][column], cosine >= minimumVoiceCosine else { continue }
                    let rowIsStrong = referenceIDs.indices.allSatisfy { other in
                        other == column || voice[row][other].map { cosine - $0 >= minimumVoiceMargin } ?? true
                    }
                    let columnIsStrong = newIDs.indices.allSatisfy { other in
                        other == row || voice[other][column].map { cosine - $0 >= minimumVoiceMargin } ?? true
                    }
                    guard rowIsStrong, columnIsStrong else { continue }
                    mapping[newIDs[row]] = referenceIDs[column]
                    matchedRows |= 1 << row
                    matchedReferences |= 1 << column
                    break
                }
            }
        }
        if mapping.count == newIDs.count { return mapping }
        var weight = Array(repeating: Array(repeating: Int64(-1), count: referenceIDs.count), count: newIDs.count)
        for (row, newID) in newIDs.enumerated() where matchedRows & (1 << row) == 0 {
            let a = newSolo[newID] ?? []
            let aTotal = a.reduce(Int64(0)) { $0 + $1.1 - $1.0 }
            for (column, referenceID) in referenceIDs.enumerated() where matchedReferences & (1 << column) == 0 {
                if let cosine = voice?[row][column], cosine < minimumVoiceCosine { continue }
                let b = referenceSolo[referenceID] ?? []
                let bTotal = b.reduce(Int64(0)) { $0 + $1.1 - $1.0 }
                let denominator = min(aTotal, bTotal)
                guard denominator > 0 else { continue }
                let shared = intersection(a, b)
                if Double(shared) / Double(denominator) >= minimumAgreement { weight[row][column] = shared }
            }
        }

        // Subset DP over reference speakers; `choice` keeps the lexicographically
        // smallest reference-ordinal assignment among equal totals.
        let masks = 1 << referenceIDs.count
        var best: [(score: Int64, choice: [Int])?] = Array(repeating: nil, count: masks)
        best[matchedReferences] = (0, [])
        for row in newIDs.indices where matchedRows & (1 << row) == 0 {
            var next: [(score: Int64, choice: [Int])?] = Array(repeating: nil, count: masks)
            for mask in 0..<masks {
                guard let current = best[mask] else { continue }
                consider(&next[mask], (current.score, current.choice + [Int.max]))
                for column in referenceIDs.indices where mask & (1 << column) == 0 && weight[row][column] >= 0 {
                    consider(&next[mask | (1 << column)], (current.score + weight[row][column], current.choice + [column]))
                }
            }
            best = next
        }
        var winner: (score: Int64, choice: [Int])?
        for candidate in best.compactMap({ $0 }) { consider(&winner, candidate) }
        guard let winner else { return mapping }
        var choiceIndex = 0
        for row in newIDs.indices where matchedRows & (1 << row) == 0 {
            let column = winner.choice[choiceIndex]
            choiceIndex += 1
            if column != Int.max { mapping[newIDs[row]] = referenceIDs[column] }
        }
        return mapping
    }

    /// Validate once per vector, then compute true cosine without copying or
    /// assuming normalization. Double accumulation handles all finite Floats.
    private static func voiceSimilarities(
        newIDs: [String],
        referenceIDs: [String],
        evidence: MeetingSpeakerVoiceEvidence?
    ) -> [[Double?]]? {
        guard let evidence else { return nil }
        let newNorms = newIDs.map { vectorNorm(evidence.newEmbeddings[$0]) }
        let referenceNorms = referenceIDs.map { vectorNorm(evidence.referenceEmbeddings[$0]) }
        guard newNorms.contains(where: { $0 != nil }), referenceNorms.contains(where: { $0 != nil }) else { return nil }
        var similarities = Array(repeating: Array<Double?>(repeating: nil, count: referenceIDs.count), count: newIDs.count)
        for row in newIDs.indices {
            guard let aNorm = newNorms[row], let a = evidence.newEmbeddings[newIDs[row]] else { continue }
            for column in referenceIDs.indices {
                guard let bNorm = referenceNorms[column], let b = evidence.referenceEmbeddings[referenceIDs[column]] else { continue }
                var dot = 0.0
                for index in 0..<256 { dot += Double(a[index]) * Double(b[index]) }
                similarities[row][column] = min(1, max(-1, dot / (aNorm * bNorm)))
            }
        }
        return similarities
    }

    private static func vectorNorm(_ vector: [Float]?) -> Double? {
        guard let vector, vector.count == 256 else { return nil }
        var squaredNorm = 0.0
        for value in vector {
            guard value.isFinite else { return nil }
            squaredNorm += Double(value) * Double(value)
        }
        return squaredNorm > 0 ? squaredNorm.squareRoot() : nil
    }

    static func firstAppearanceOrder(_ intervals: [MeetingSpeakerInterval]) -> [String] {
        var seen = Set<String>()
        return intervals
            .sorted { ($0.startSample, $0.speakerID) < ($1.startSample, $1.speakerID) }
            .compactMap { seen.insert($0.speakerID).inserted ? $0.speakerID : nil }
    }

    /// Disjoint, sorted regions where exactly one speaker is active.
    static func soloActivity(_ intervals: [MeetingSpeakerInterval]) -> [String: [(Int64, Int64)]] {
        var events: [(sample: Int64, delta: Int, speaker: String)] = []
        for interval in intervals where interval.endSample > interval.startSample {
            events.append((interval.startSample, 1, interval.speakerID))
            events.append((interval.endSample, -1, interval.speakerID))
        }
        events.sort { ($0.sample, $0.delta) < ($1.sample, $1.delta) }
        var active: [String: Int] = [:]
        var solo: [String: [(Int64, Int64)]] = [:]
        var index = 0
        var previous: Int64?
        while index < events.count {
            let sample = events[index].sample
            if let previous, sample > previous, active.count == 1, let speaker = active.keys.first {
                if let last = solo[speaker]?.last, last.1 == previous {
                    solo[speaker]![solo[speaker]!.count - 1].1 = sample
                } else {
                    solo[speaker, default: []].append((previous, sample))
                }
            }
            while index < events.count, events[index].sample == sample {
                let event = events[index]
                let count = (active[event.speaker] ?? 0) + event.delta
                active[event.speaker] = count > 0 ? count : nil
                index += 1
            }
            previous = sample
        }
        return solo
    }

    private static func intersection(_ a: [(Int64, Int64)], _ b: [(Int64, Int64)]) -> Int64 {
        var i = 0, j = 0
        var total: Int64 = 0
        while i < a.count, j < b.count {
            total += max(0, min(a[i].1, b[j].1) - max(a[i].0, b[j].0))
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return total
    }

    private static func consider(_ slot: inout (score: Int64, choice: [Int])?, _ candidate: (score: Int64, choice: [Int])) {
        guard let existing = slot else { slot = candidate; return }
        if isBetter(candidate, than: existing) { slot = candidate }
    }

    private static func isBetter(_ a: (score: Int64, choice: [Int]), than b: (score: Int64, choice: [Int])) -> Bool {
        a.score != b.score ? a.score > b.score : a.choice.lexicographicallyPrecedes(b.choice)
    }
}
