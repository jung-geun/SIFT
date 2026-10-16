import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Captured Apple transcript persistence")
@MainActor
struct MeetingCaptureTranscriptPersisterTests {
    private enum Failure: Error { case save }

    @Test("A failed analyzer preserves its latest available Apple text and both original baselines")
    func failedAnalyzerKeepsDrainedText() throws {
        let (context, record, initial) = try fixture()
        let originalManifest = record.manifestData
        let expected = record.resultData
        let latest = result("Apple text accepted while finishing", end: 2_000)
        #expect(try MeetingCaptureTranscriptPersister.persist(record: record, baseline: latest, failed: true,
            expectedResultData: expected, in: context))
        #expect(record.status == .transcriptFinalizationFailed)
        #expect(record.result == latest)
        #expect(record.rawResult == latest)
        #expect(record.appleRawResult == latest)
        #expect(record.manifestData == originalManifest)
        #expect(record.result != initial)
    }

    @Test("A newer edited child remains intact and no longer stays permanently finalizing")
    func editedChildSettlesWithoutReplacement() throws {
        let (context, record, initial) = try fixture()
        let expected = record.resultData
        var edited = initial
        edited.transcriptRevision = 1
        edited.segments[0].text = "User correction"
        try record.update(result: edited, status: .finalizingTranscript)
        try context.save()
        let editedData = record.resultData
        let originalRaw = record.rawResultData
        let latestApple = result("Later Apple result", end: 2_000)
        #expect(try MeetingCaptureTranscriptPersister.persist(record: record, baseline: latestApple, failed: false,
            expectedResultData: expected, in: context) == false)
        #expect(record.status == .ready)
        #expect(record.resultData == editedData)
        #expect(record.result?.segments[0].text == "User correction")
        #expect(record.rawResultData == originalRaw)
        #expect(record.appleRawResult == latestApple)
    }

    @Test("A failed baseline commit restores status, current text and both Apple snapshots")
    func failedSaveIsAtomic() throws {
        let (context, record, _) = try fixture()
        let before = record.persistenceSnapshot()
        #expect(throws: Failure.save) {
            try MeetingCaptureTranscriptPersister.persist(record: record,
                baseline: result("Latest Apple", end: 2_000), failed: true,
                expectedResultData: record.resultData, in: context) { _ in throw Failure.save }
        }
        #expect(record.persistenceSnapshot() == before)
    }

    private func fixture() throws -> (ModelContext, MeetingRecord, MeetingResult) {
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let record = MeetingRecord(meetingID: UUID().uuidString.lowercased())
        let initial = result("Initial Apple text", end: 1_000)
        try record.replaceTranscriptionBase(initial, status: .finalizingTranscript)
        try record.update(audioManifest: MeetingAudioManifest(relativeDirectory: "\(record.meetingID)/audio",
            sampleRate: 16_000, totalSamples: 32_000,
            parts: [MeetingAudioPartManifest(fileName: "part-00.flac", partIndex: 0, partStartSample: 0,
                ownedStartSample: 0, ownedEndSample: 32_000)]))
        context.insert(record)
        try context.save()
        return (context, record, initial)
    }

    private func result(_ text: String, end: Int64) -> MeetingResult {
        MeetingResult(segments: [MeetingSegment(id: "apple-source", startMs: 0, endMs: end, text: text)])
    }
}
