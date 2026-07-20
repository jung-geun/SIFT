import Foundation

extension MeetingRecord {
    var audioManifest: MeetingAudioManifest? {
        try? JSONDecoder().decode(MeetingAudioManifest.self, from: manifestData)
    }

    func update(audioManifest: MeetingAudioManifest) throws {
        manifestData = try JSONEncoder().encode(audioManifest)
        updatedAt = Date()
    }
}
