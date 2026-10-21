import Foundation

extension MeetingFLACPartWriter {
    /// A snapshot of closed parts only. `totalSamples` on the writer also counts
    /// the open native file and is progress, not a decoder publication boundary.
    nonisolated func manifest(relativeDirectory: String) -> MeetingAudioManifest {
        MeetingAudioManifest(
            relativeDirectory: relativeDirectory,
            sampleRate: MeetingMediaTimeline.sampleRate,
            totalSamples: completedParts.last?.ownedEndSample ?? 0,
            parts: completedParts.map {
                MeetingAudioPartManifest(
                    fileName: String(format: "part-%02d.flac", $0.index),
                    partIndex: $0.index,
                    partStartSample: $0.partStartSample,
                    ownedStartSample: $0.ownedStartSample,
                    ownedEndSample: $0.ownedEndSample
                )
            }
        )
    }
}
