import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Local meeting audio import")
@MainActor
struct MeetingAudioImportTests {
    private struct Fixture {
        let directory: URL
        let root: URL
        let source: URL
        let sentinel: URL

        init(fileExtension: String = "wav") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-import-\(UUID().uuidString)", isDirectory: true)
            root = directory.appendingPathComponent("meetings", isDirectory: true)
            source = directory.appendingPathComponent("Planning.\(fileExtension)")
            sentinel = root.appendingPathComponent("existing-recording")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("preserve me".utf8).write(to: sentinel)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func expectNoImportOutput() throws {
            let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            #expect(contents.map(\.lastPathComponent) == [sentinel.lastPathComponent])
            #expect(try Data(contentsOf: sentinel) == Data("preserve me".utf8))
        }
    }

    private func container() throws -> ModelContainer {
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        container.mainContext.autosaveEnabled = false
        return container
    }

    /// Synthesizes on disk using one reused buffer, including the long fixture.
    private func writeAudio(to url: URL, sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2, seconds: Int = 2) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let samples = try #require(buffer.floatChannelData)
        let totalFrames = Int(sampleRate) * seconds
        var frame = 0
        while frame < totalFrames {
            let count = min(4_096, totalFrames - frame)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(channels) {
                for index in 0..<count {
                    samples[channel][index] = Float(sin(Double(frame + index) * 2 * .pi * 440 / sampleRate) * 0.25)
                }
            }
            try file.write(from: buffer)
            frame += count
        }
    }

    private func records(in context: ModelContext) throws -> [MeetingRecord] {
        try context.fetch(FetchDescriptor<MeetingRecord>())
    }

    @Test("44.1 kHz stereo is saved as playable 16 kHz mono with truthful provenance")
    func stereoResamplingAndPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeAudio(to: fixture.source)
        let original = try Data(contentsOf: fixture.source)
        let store = try container()
        let record = try await MeetingAudioImportService.importFile(
            at: fixture.source, languageTag: "en-US", in: store.mainContext, rootURL: fixture.root
        )
        let manifest = try #require(record.audioManifest)
        #expect(manifest.sampleRate == 16_000)
        #expect(abs(manifest.totalSamples - 32_000) <= 1)
        #expect(manifest.parts.count == 1)
        #expect(manifest.relativeDirectory == "\(record.meetingID)/audio")
        #expect(record.importedAudioFileName == "Planning.wav")
        #expect(record.result?.title == "Planning")
        #expect(record.result?.segments.isEmpty == true)
        #expect(record.rawResult == record.result)
        #expect(record.appleRawResultData == nil)
        #expect(record.asrSource == .importedAudio)
        #expect(record.asrModelRevision == nil)
        #expect(record.status == .transcriptFinalizationFailed)
        #expect(record.mode == .onDevice)
        #expect(record.languageTag == "en-US")
        #expect(!record.automaticLanguageDetection)
        let persisted = try #require(try records(in: ModelContext(store)).first)
        #expect(persisted.importedAudioFileName == "Planning.wav")
        #expect(persisted.audioManifest == manifest)
        #expect(try Data(contentsOf: fixture.source) == original)

        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let cursor = try MeetingLogicalAudioCursor(manifest: manifest, rootURL: fixture.root)
        var total: Int64 = 0
        var energy: Double = 0
        while let buffer = try cursor.nextPCMBuffer(maxFrames: 4_096, outputFormat: output) {
            total += Int64(buffer.frameLength)
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0..<Int(buffer.frameLength) { energy += Double(samples[frame] * samples[frame]) }
        }
        #expect(total == manifest.totalSamples)
        // A real tone survived stereo downmix and conversion (not silent output).
        #expect(energy / Double(total) > 0.01)
        #expect(energy / Double(total) < 0.1)
    }

    @Test("long streamed import rotates FLAC parts and plays an overlap-free timeline")
    func streamedPartRotation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeAudio(to: fixture.source, sampleRate: 16_000, channels: 1, seconds: 601)
        let store = try container()
        let record = try await MeetingAudioImportService.importFile(
            at: fixture.source, languageTag: "ko-KR", in: store.mainContext, rootURL: fixture.root
        )
        let manifest = try #require(record.audioManifest)
        #expect(manifest.totalSamples == 601 * 16_000)
        #expect(manifest.parts.count == 2)
        let second = try #require(manifest.parts.last)
        #expect(second.partStartSample == MeetingMediaTimeline.ownedSamplesPerPart - MeetingMediaTimeline.overlapSamples)
        #expect(second.ownedStartSample == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(second.ownedEndSample == manifest.totalSamples)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let cursor = try MeetingLogicalAudioCursor(manifest: manifest, rootURL: fixture.root)
        var frames: Int64 = 0
        while let buffer = try cursor.nextPCMBuffer(maxFrames: 4_096, outputFormat: format) {
            frames += Int64(buffer.frameLength)
        }
        #expect(frames == manifest.totalSamples)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test("cancellation during conversion removes only newly owned output")
    func cancelledConversionRollsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeAudio(to: fixture.source)
        let original = try Data(contentsOf: fixture.source)
        let store = try container()
        do {
            _ = try await MeetingAudioImportService.importFile(
                at: fixture.source, languageTag: "en-US", in: store.mainContext, rootURL: fixture.root,
                progress: { _ in
                    // Deterministic: first notification follows actual FLAC append.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
            Issue.record("Cancelled conversion unexpectedly committed")
        } catch is CancellationError {
        }
        #expect(try records(in: store.mainContext).isEmpty)
        try fixture.expectNoImportOutput()
        #expect(try Data(contentsOf: fixture.source) == original)
    }

    @Test("save failure removes output without rolling back unrelated local edits")
    func failedSaveRollsBackOnlyImport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeAudio(to: fixture.source)
        let original = try Data(contentsOf: fixture.source)
        let store = try container()
        let existing = MeetingRecord()
        try existing.update(result: MeetingResult(title: "Keep this edit"))
        store.mainContext.insert(existing)
        enum SaveFailure: Error { case rejected }
        do {
            _ = try await MeetingAudioImportService.importFile(
                at: fixture.source, languageTag: "en-US", in: store.mainContext, rootURL: fixture.root,
                save: { _ in throw SaveFailure.rejected }
            )
            Issue.record("Rejected save unexpectedly succeeded")
        } catch {
            #expect(error as? MeetingAudioImportService.Failure == .storageFailed)
        }
        let remaining = try records(in: store.mainContext)
        #expect(remaining.count == 1)
        #expect(remaining.first?.meetingID == existing.meetingID)
        #expect(existing.result?.title == "Keep this edit")
        try fixture.expectNoImportOutput()
        #expect(try Data(contentsOf: fixture.source) == original)
    }

    @Test("missing, corrupt, and empty source files leave no meeting or files", arguments: ["missing", "corrupt", "empty"])
    func rejectedInputRollsBack(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        switch kind {
        case "corrupt": try Data("not an audio stream".utf8).write(to: fixture.source)
        case "empty": try writeAudio(to: fixture.source, seconds: 0)
        default: break
        }
        let original = try? Data(contentsOf: fixture.source)
        let store = try container()
        do {
            _ = try await MeetingAudioImportService.importFile(
                at: fixture.source, languageTag: "ko-KR", in: store.mainContext, rootURL: fixture.root
            )
            Issue.record("Invalid input unexpectedly imported")
        } catch {
            #expect(error is MeetingAudioImportService.Failure)
        }
        #expect(try records(in: store.mainContext).isEmpty)
        try fixture.expectNoImportOutput()
        #expect((try? Data(contentsOf: fixture.source)) == original)
    }

    @Test("manual imports reject unsupported catalog tags without creating a record or audio", arguments: ["auto", "xx-Invalid", ""])
    func manualLanguageValidation(tag: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeAudio(to: fixture.source)
        let store = try container()
        await #expect(throws: MeetingOfflineTranscriptionService.Failure.unsupportedLanguage) {
            try await MeetingAudioImportService.importFile(
                at: fixture.source, languageTag: tag, in: store.mainContext, rootURL: fixture.root)
        }
        #expect(try records(in: store.mainContext).isEmpty)
        try fixture.expectNoImportOutput()
    }

    @Test("a missing Whisper model keeps automatic imported audio retryable, not successfully transcribed")
    func modelFailurePreservesImportedBase() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeAudio(to: fixture.source)
        let store = try container()
        let record = try await MeetingAudioImportService.importFile(
            at: fixture.source, languageTag: "en-US", automaticLanguageDetection: true,
            summaryLanguageTag: "fr-FR", in: store.mainContext, rootURL: fixture.root
        )
        let manifest = record.manifestData
        let base = record.resultData
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(
            gate: MeetingDiarizationExecutionGate(),
            transcribe: { _, _, language in
                #expect(language == nil)
                throw MeetingWhisperModelError.notInstalled
            }
        )
        do {
            _ = try await orchestrator.run(record: record, context: store.mainContext)
            Issue.record("Missing model unexpectedly transcribed")
        } catch {
            #expect(error is MeetingWhisperModelError)
        }
        #expect(record.resultData == base)
        #expect(record.manifestData == manifest)
        #expect(record.status == .transcriptFinalizationFailed)
        #expect(record.asrSource == .importedAudio)
        #expect(record.offlineASRFailure == .modelUnavailable)
        #expect(record.appleRawResultData == nil)
        let audio = fixture.root.appendingPathComponent(try #require(record.audioManifest).relativeDirectory)
        #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent("part-00.flac").path))
        let originalFLAC = try Data(contentsOf: audio.appendingPathComponent("part-00.flac"))
        let retry = MeetingOfflineTranscriptionOrchestrator(gate: MeetingDiarizationExecutionGate()) { _, revision, language in
            #expect(language == nil)
            return MeetingOfflineTranscriptionService.Output(
                result: MeetingResult(transcriptRevision: revision + 1, segments: [
                    MeetingSegment(id: "retry", startMs: 0, endMs: 1_000, text: "Retried audio")
                ]), sourceTranscriptRevision: revision, detectedLanguages: ["ko", "en"])
        }
        #expect(try await retry.run(record: record, context: store.mainContext) == .committed)
        let persisted = try #require(records(in: ModelContext(store)).first)
        #expect(persisted.automaticLanguageDetection)
        #expect(persisted.languageTag == "en-US")
        #expect(persisted.summaryLanguageTag == "fr-FR")
        #expect(persisted.asrDetectedLanguages == ["ko", "en"])
        #expect(persisted.rawResult == persisted.result)
        #expect(persisted.result?.segments.first?.text == "Retried audio")
        #expect(persisted.offlineASRFailure == nil)
        #expect(try Data(contentsOf: audio.appendingPathComponent("part-00.flac")) == originalFLAC)
    }
}

@Suite("Imported recording offline retry")
@MainActor
struct MeetingAudioImportRetryTests {
    @Test("normal offline orchestration replaces an imported empty base without inventing Apple provenance", arguments: [false, true])
    func offlineCommitUsesNormalMeetingContract(automatic: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let source = directory.appendingPathComponent("Original.caf")
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<16_000 { channel[index] = 0 }
            try file.write(from: buffer)
        }
        let store = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let record = try await MeetingAudioImportService.importFile(
            at: source, languageTag: "ko-KR", automaticLanguageDetection: automatic,
            in: store.mainContext, rootURL: directory
        )
        let manifest = record.manifestData
        let orchestrator = MeetingOfflineTranscriptionOrchestrator(
            gate: MeetingDiarizationExecutionGate(),
            transcribe: { savedAudio, revision, language in
                await MainActor.run {
                    #expect(savedAudio.totalSamples == 16_000)
                    #expect(revision == 0)
                    #expect(language == (automatic ? nil : "ko-KR"))
                    return MeetingOfflineTranscriptionService.Output(
                        result: MeetingResult(transcriptRevision: revision + 1, segments: [
                            MeetingSegment(id: "imported-segment", startMs: 0, endMs: 1_000, text: "실제 전사 결과 계약")
                        ]), sourceTranscriptRevision: revision, detectedLanguages: ["ko"]
                    )
                }
            }
        )
        let outcome = try await orchestrator.run(record: record, context: store.mainContext)
        #expect(outcome == .committed)
        #expect(record.status == .ready)
        #expect(record.asrSource == .offline)
        #expect(record.asrModelRevision == MeetingWhisperManifest.modelRevision)
        #expect(record.asrDetectedLanguages == (automatic ? ["ko"] : []))
        #expect(record.automaticLanguageDetection == automatic)
        #expect(record.languageTag == "ko-KR")
        #expect(record.result?.transcriptRevision == 1)
        #expect(record.rawResult == record.result)
        #expect(record.appleRawResultData == nil)
        #expect(record.importedAudioFileName == "Original.caf")
        #expect(record.manifestData == manifest)
        #expect(record.offlineASRFailure == nil)
    }
}
