import Foundation

/// A derived playback projection only; manifests and original FLAC files are never changed.
nonisolated struct MeetingGroupAudioPlaybackPlan: Sendable, Equatable {
    nonisolated struct Source: Sendable, Equatable {
        let trackID: String
        let manifest: MeetingAudioManifest
        let startSample: Int64
    }

    nonisolated struct ExcludedSource: Sendable, Equatable {
        nonisolated enum Reason: Sendable, Equatable {
            case notInGroup, unknownTiming, missingAudio
        }
        let trackID: String
        let reason: Reason
    }

    nonisolated enum PlanError: Error, Equatable {
        case noAlignedSources
        case invalidSource(String)
    }

    let totalSamples: Int64
    let sampleRate: Int64
    let sources: [Source]
    let excludedSources: [ExcludedSource]
    var isComplete: Bool { excludedSources.isEmpty }

    @MainActor
    static func make(tracks: [MeetingRecord], groupID: String) throws -> Self {
        var sources: [Source] = []
        var excluded: [ExcludedSource] = []
        for track in tracks {
            guard track.parentMeetingID == groupID else {
                excluded.append(ExcludedSource(trackID: track.meetingID, reason: .notInGroup))
                continue
            }
            if let kind = track.audioTrackKind, kind != .legacyMixed,
               (track.audioTrackStartSample < 0 || track.audioTrackStartSample > MeetingMediaTimeline.maximumSamples) {
                throw PlanError.invalidSource(track.meetingID)
            }
            guard let offset = track.conversationStartSample else {
                excluded.append(ExcludedSource(trackID: track.meetingID, reason: .unknownTiming))
                continue
            }
            guard let manifest = track.audioManifest else {
                // Undecodable nonempty data is corruption, not an absent recording.
                guard track.manifestData.isEmpty else { throw PlanError.invalidSource(track.meetingID) }
                excluded.append(ExcludedSource(trackID: track.meetingID, reason: .missingAudio))
                continue
            }
            if manifest.totalSamples == 0, manifest.parts.isEmpty {
                excluded.append(ExcludedSource(trackID: track.meetingID, reason: .missingAudio))
                continue
            }
            sources.append(Source(trackID: track.meetingID, manifest: manifest, startSample: offset))
        }
        return try Self(sources: sources, excludedSources: excluded, requiresSessionRate: true)
    }

    init(sources: [Source]) throws {
        try self.init(sources: sources, excludedSources: [], requiresSessionRate: true)
    }

    /// Single-source playback retains its source-local clock and format; no group alignment is inferred.
    static func single(manifest: MeetingAudioManifest) throws -> Self {
        try Self(sources: [Source(trackID: manifest.relativeDirectory, manifest: manifest, startSample: 0)],
                 excludedSources: [], requiresSessionRate: false)
    }

    private init(sources: [Source], excludedSources: [ExcludedSource], requiresSessionRate: Bool) throws {
        guard !sources.isEmpty else { throw PlanError.noAlignedSources }
        var ids = Set<String>()
        var end: Int64 = 0
        let rate = sources[0].manifest.sampleRate
        for source in sources {
            guard ids.insert(source.trackID).inserted,
                  !source.trackID.isEmpty,
                  source.startSample >= 0,
                  source.startSample <= MeetingMediaTimeline.maximumSamples,
                  source.manifest.totalSamples > 0,
                  source.manifest.totalSamples <= MeetingMediaTimeline.maximumSamples - source.startSample,
                  source.manifest.sampleRate == rate,
                  !requiresSessionRate || rate == MeetingMediaTimeline.sampleRate else {
                throw PlanError.invalidSource(source.trackID)
            }
            do { _ = try MeetingLogicalAudioCursor.validatedParts(for: source.manifest) }
            catch { throw PlanError.invalidSource(source.trackID) }
            end = max(end, source.startSample + source.manifest.totalSamples)
        }
        self.sources = sources.sorted {
            ($0.startSample, $0.trackID) < ($1.startSample, $1.trackID)
        }
        self.excludedSources = excludedSources.sorted { $0.trackID < $1.trackID }
        self.totalSamples = end
        self.sampleRate = rate
    }
}
