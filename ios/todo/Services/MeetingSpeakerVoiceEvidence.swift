import Foundation

/// Meeting-local evidence only; neither speaker names nor persisted voice profiles.
nonisolated struct MeetingSpeakerVoiceEvidence: Sendable {
    let newEmbeddings: [String: [Float]]
    let referenceEmbeddings: [String: [Float]]
}

/// Selects bounded, contiguous solo clips on the canonical 16 kHz sample clock.
nonisolated enum MeetingSpeakerEmbeddingWindows {
    nonisolated struct Window: Hashable, Sendable {
        let speakerID: String
        let startSample: Int64
        let endSample: Int64
    }

    static let minimumSamples: Int64 = 32_000
    static let targetSamples: Int64 = 48_000
    static let maximumWindowsPerSpeaker = 3
    private static let transitionSamples: Int64 = 1_600
    private static let maximumSpeakers = 8

    static func select(intervals: [MeetingSpeakerInterval], totalSamples: Int64) -> [Window] {
        guard totalSamples > 0 else { return [] }
        let bounded = intervals.compactMap { interval -> MeetingSpeakerInterval? in
            let start = max(0, interval.startSample)
            let end = min(totalSamples, interval.endSample)
            guard end > start else { return nil }
            return MeetingSpeakerInterval(speakerID: interval.speakerID, startSample: start, endSample: end)
        }
        // The sweep merges same-ID touching/overlapping runs, but splits at all
        // other-ID activity. Even speakers beyond the output cap remain blockers.
        let solo = MeetingSpeakerIdentityMatcher.soloActivity(bounded)
        let orderedIDs = solo.keys.sorted {
            (solo[$0]!.first!.0, $0) < (solo[$1]!.first!.0, $1)
        }
        var windows: [Window] = []
        windows.reserveCapacity(maximumSpeakers * maximumWindowsPerSpeaker)
        var selectedSpeakers = 0
        for speakerID in orderedIDs {
            guard selectedSpeakers < maximumSpeakers else { break }
            let regions = solo[speakerID] ?? []
            let available = regions.reduce(Int64(0)) { total, region in
                total + clipCount(cleanLength: region.1 - region.0 - 2 * transitionSamples)
            }
            guard available > 0 else { continue }
            let count = Int(min(Int64(maximumWindowsPerSpeaker), available))
            var selected = 0
            var preceding: Int64 = 0
            for (start, end) in regions {
                let cleanLength = end - start - 2 * transitionSamples
                let clips = clipCount(cleanLength: cleanLength)
                // Select first/middle/last eligible clips across all solo speech,
                // without materializing every possible window in a long meeting.
                while selected < count {
                    let divisor = Int64(max(1, count - 1))
                    let rank = ((available - 1) * Int64(selected) + divisor / 2) / divisor
                    guard rank < preceding + clips else { break }
                    let offset = (rank - preceding) * targetSamples
                    let lower = start + transitionSamples + offset
                    windows.append(Window(speakerID: speakerID, startSample: lower,
                                          endSample: lower + min(targetSamples, cleanLength - offset)))
                    selected += 1
                }
                preceding += clips
                if selected == count { break }
            }
            selectedSpeakers += 1
        }
        return windows.sorted {
            ($0.startSample, $0.endSample, $0.speakerID) < ($1.startSample, $1.endSample, $1.speakerID)
        }
    }

    private static func clipCount(cleanLength: Int64) -> Int64 {
        guard cleanLength >= minimumSamples else { return 0 }
        return cleanLength / targetSamples + (cleanLength % targetSamples >= minimumSamples ? 1 : 0)
    }
}
