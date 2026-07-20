import Foundation

extension MeetingFLACPartWriter {
    func manifest(relativeDirectory: String) -> MeetingAudioManifest {
        MeetingAudioManifest(
            relativeDirectory: relativeDirectory,
            sampleRate: MeetingMediaTimeline.sampleRate,
            totalSamples: totalSamples,
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
