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
    }

    struct Entry {
        let id: String
        let startMs: Int64
        let endMs: Int64
        let text: String
        let speakerIDs: [String]
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

    let rows: [Row]
    /// Deliberately not appended to `rows`: their position relative to other sources is unknown.
    let unalignedSources: [UnalignedSource]

    init(sources: [Source]) {
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
                    text: entry.text, speakerIDs: entry.speakerIDs)
            }
            if hasCommonTime {
                aligned.append(contentsOf: projected)
            } else {
                unaligned.append(UnalignedSource(id: source.trackID, rows: projected.sorted {
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
                             text: row.text, speakerIDs: row.speakerIDs)
            }
            return Source(trackID: track.meetingID, sessionStartSample: track.sessionStartSample, entries: entries)
        })
    }

    static func saved(_ tracks: [MeetingRecord], groupID: String) -> Self {
        Self(sources: tracks.map { track in
            Source(trackID: track.meetingID,
                   sessionStartSample: track.parentMeetingID == groupID ? track.conversationStartSample : nil,
                   entries: (track.result?.segments ?? []).map {
                Entry(id: $0.stableLineageID, startMs: $0.startMs, endMs: $0.endMs,
                      text: $0.text, speakerIDs: $0.speakerIDs)
            })
        })
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
