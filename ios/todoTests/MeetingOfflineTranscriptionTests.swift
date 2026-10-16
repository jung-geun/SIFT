import AVFoundation
import CryptoKit
import Foundation
import Testing
import WhisperKit
@testable import todo

@MainActor
@Suite("Saved FLAC offline transcription")
struct MeetingOfflineTranscriptionTests {
    private typealias Service = MeetingOfflineTranscriptionService

    private func word(_ text: String, _ start: Float, _ end: Float, probability: Float = 0.9) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: end, probability: probability)
    }

    private func result(_ segments: [TranscriptionSegment], language: String = "ko", seek: Float? = nil) -> TranscriptionResult {
        TranscriptionResult(text: segments.map(\.text).joined(), segments: segments,
                            language: language, timings: TranscriptionTimings(), seekTime: seek)
    }

    private func convert(_ segment: TranscriptionSegment, totalSamples: Int64 = 160_000) throws -> MeetingSegment {
        let output = try Service.makeOutput([result([segment])], totalSamples: totalSamples, sourceTranscriptRevision: 3)
        return try #require(output.result.segments.first)
    }

    @Test("UTF-16 runs address literal Korean, emoji, combining marks, and English")
    func unicodeRanges() throws {
        let source = TranscriptionSegment(start: 1, end: 4, text: "  안녕 👩🏽‍💻 cafe\u{301}!  ", words: [
            word(" 안녕", 1, 1.5), word(" 👩🏽‍💻", 2, 2.5), word(" cafe\u{301}!", 3, 4)
        ])
        let segment = try convert(source)
        #expect(segment.text == source.text)
        let runs = try #require(segment.timedRuns)
        #expect(runs == [
            MeetingTimedTextRun(utf16Offset: 2, utf16Length: 2, startMs: 1_000, endMs: 1_500),
            MeetingTimedTextRun(utf16Offset: 5, utf16Length: 7, startMs: 2_000, endMs: 2_500),
            MeetingTimedTextRun(utf16Offset: 13, utf16Length: 6, startMs: 3_000, endMs: 4_000)
        ])
        #expect(runs.map { (segment.text as NSString).substring(with: NSRange(location: $0.utf16Offset, length: $0.utf16Length)) }
                == ["안녕", "👩🏽‍💻", "cafe\u{301}!"])
    }

    @Test("Partial graphemes and canonically equivalent but nonliteral spellings are not aligned")
    func ambiguousUnicode() throws {
        for (text, words) in [
            ("👩🏽‍💻", [word("👩", 0, 0.5), word("🏽‍💻", 0.5, 1)]),
            ("cafe\u{301}", [word("café", 0, 1)]),
            ("안녕", [word("안", 0, 0.5)])
        ] {
            let segment = try convert(TranscriptionSegment(start: 0, end: 1, text: text, words: words))
            #expect(segment.text == text)
            #expect(segment.timedRuns == nil)
        }
    }

    @Test("Repeated words match in place; skipped or missing text cannot acquire timing")
    func literalCoverage() throws {
        let complete = try convert(TranscriptionSegment(start: 0, end: 2, text: "go go", words: [
            word("go", 0, 0.5), word(" go", 1, 2)
        ]))
        #expect(complete.timedRuns?.map(\.utf16Offset) == [0, 3])
        for words in [
            [word("go", 0, 1)],
            [word("missing", 0, 0.5), word("go", 1, 2)],
            [word(" ", 0, 0.5), word("go go", 1, 2)]
        ] {
            #expect(try convert(TranscriptionSegment(start: 0, end: 2, text: "go go", words: words)).timedRuns == nil)
        }
    }

    @Test("Absolute SDK timestamps preserve silence and are not offset again by seek or result count")
    func absoluteTimeline() throws {
        let early = result([TranscriptionSegment(id: 7, seek: 480_000, start: 30.5, end: 31, text: "hello",
                                                words: [word("hello", 30.5, 31)])], language: "en", seek: 30)
        let silence = result([], seek: 60)
        let late = result([TranscriptionSegment(id: 7, seek: 1_440_000, start: 91, end: 92, text: "안녕",
                                               words: [word("안녕", 91, 92)])], seek: 90)
        let output = try Service.makeOutput([late, silence, early], totalSamples: 1_600_000, sourceTranscriptRevision: 8)
        #expect(output.result.segments.map(\.startMs) == [30_500, 91_000])
        #expect(output.result.segments.map(\.endMs) == [31_000, 92_000])
        #expect(output.result.segments.flatMap { $0.timedRuns ?? [] }.map(\.startMs) == [30_500, 91_000])
        #expect(output.sourceTranscriptRevision == 8)
        #expect(output.result.transcriptRevision == 9)
        #expect(output.result.segments.allSatisfy { UUID(uuidString: $0.id) != nil && $0.speakerIDs.isEmpty && $0.lineageID == nil })
        #expect(Set(output.result.segments.map(\.id)).count == 2)
        #expect(try output.result.validated() == output.result)
    }

    @Test("SDK zero-duration words preserve the complete transcript without invented word timing")
    func zeroDurationWords() throws {
        // WhisperKit 1.1.0 SegmentSeeker.updateSegmentsWithWordTimings explicitly
        // retains [0.5–2.0], [2.0–2.0] when there is no gap to expand the word.
        // Use the SDK's real incremental-offset utility, not an app-added seek.
        let local = TranscriptionSegment(start: 0.5, end: 2, text: "one two", words: [
            word("one", 0.5, 2), word(" two", 2, 2)
        ])
        let absolute = TranscriptionUtilities.updateSegmentTimings(segment: local, seekOffsetIndex: 480_000)
        let measured = TranscriptionSegment(start: 1, end: 2, text: "안녕", words: [word("안녕", 1, 2)])
        let output = try Service.makeOutput([result([measured]), result([absolute], language: "en", seek: 30)],
                                          totalSamples: 640_000, sourceTranscriptRevision: 3)
        #expect(output.result.segments.map(\.text) == ["안녕", "one two"])
        #expect(output.result.segments.map(\.startMs) == [1_000, 30_500])
        #expect(output.result.segments.map(\.endMs) == [2_000, 32_000])
        #expect(output.result.segments[0].timedRuns?.count == 1)
        #expect(output.result.segments[1].timedRuns == nil)
        #expect(output.detectedLanguages == ["ko", "en"])
        #expect(output.sourceTranscriptRevision == 3)
        #expect(output.result.transcriptRevision == 4)
        #expect(try output.result.validated() == output.result)

        // No partial coverage or invented duration if the zero interval occurs
        // first, in the middle, or across every word instead of at the tail.
        for words in [
            [word("one", 0, 0), word(" two", 0, 1)],
            [word("one", 0, 0), word(" two", 0, 0)],
            [word("one", 0, 0.5), word(" two", 0.5, 0.5), word(" three", 0.5, 1)]
        ] {
            let text = words.map(\.word).joined()
            let segment = try convert(TranscriptionSegment(start: 0, end: 1, text: text, words: words))
            #expect(segment.text == text)
            #expect(segment.timedRuns == nil)
        }
    }

    @Test("Empty timestamp slices do not discard adjacent speech or invent language")
    func emptyTimestampMarkers() throws {
        // findSeekPointAndSegments decodes only non-special tokens. A slice
        // containing just one timestamp has equal bounds and empty text.
        // TranscribeTask normally filters it when alignment weights are present;
        // the adapter must not demand a speech interval from an empty marker.
        let marker = TranscriptionSegment(start: 0, end: 0, text: "")
        let speech = TranscriptionSegment(start: 1, end: 2, text: "hello", words: [word("hello", 1, 2)])
        let output = try Service.makeOutput([result([marker]), result([speech], language: "en")],
                                          totalSamples: 160_000, sourceTranscriptRevision: 0)
        #expect(output.result.segments.map(\.text) == ["hello"])
        #expect(output.result.segments.first?.timedRuns?.first?.startMs == 1_000)
        #expect(output.detectedLanguages == ["en"])
        let silent = try Service.makeOutput([result([marker])], totalSamples: 0, sourceTranscriptRevision: 0)
        #expect(silent.result.segments.isEmpty)
        #expect(silent.detectedLanguages.isEmpty)
    }

    @Test("Silence stays empty without placeholder text or invented language")
    func silence() throws {
        let output = try Service.makeOutput([result([])], totalSamples: 480_000, sourceTranscriptRevision: 0)
        #expect(output.result.segments.isEmpty)
        #expect(output.result.summary.isEmpty)
        #expect(output.detectedLanguages.isEmpty)
        #expect(output.languageTag == nil)
        #expect(try Service.makeOutput([], totalSamples: 0, sourceTranscriptRevision: 0).result.segments.isEmpty)
    }

    @Test("Detected languages are retained and UI locale tags select exact language semantics")
    func languages() throws {
        #expect(try Service.languageCode(for: nil) == nil)
        #expect(try Service.languageCode(for: "ko-KR") == "ko")
        #expect(try Service.languageCode(for: "en-US") == "en")
        #expect(try Service.languageCode(for: "ko") == "ko")
        let segment = TranscriptionSegment(start: 0, end: 1, text: "hello 안녕")
        let mixed = try Service.makeOutput([result([segment], language: "ko"), result([segment], language: "en")],
                                          totalSamples: 16_000, sourceTranscriptRevision: 0)
        #expect(mixed.detectedLanguages == ["ko", "en"])
        #expect(mixed.languageTag == nil)
        for (detected, tag) in [("ko", "ko-KR"), ("en", "en-US"), ("ja", "ja-JP")] {
            let output = try Service.makeOutput([result([segment], language: detected)], totalSamples: 16_000, sourceTranscriptRevision: 0)
            #expect(output.languageTag == tag)
        }
    }

    @Test("Non-finite, negative, reversed, and outside-decoder timestamps fail explicitly")
    func invalidTimestamps() throws {
        let invalid: [(Float, Float)] = [(.nan, 1), (0, .nan), (.infinity, .infinity), (0, .infinity),
                                       (-1, 1), (0, -1), (2, 1), (0, 31), (31, 32), (0, .greatestFiniteMagnitude)]
        for (start, end) in invalid {
            #expect(throws: Service.Failure.invalidTimestamps) {
                try convert(TranscriptionSegment(start: start, end: end, text: "private transcript"))
            }
            #expect(throws: Service.Failure.invalidTimestamps) {
                try convert(TranscriptionSegment(start: 0, end: 3, text: "private transcript", words: [
                    word("mismatch", 0, 0.5), word("transcript", start, end)
                ]))
            }
            // Corruption is still rejected after a legitimate zero-duration word
            // or on an empty marker, not hidden by an alignment/empty-text skip.
            #expect(throws: Service.Failure.invalidTimestamps) {
                try convert(TranscriptionSegment(start: 0, end: 3, text: "one two", words: [
                    word("one", 0, 0), word(" two", start, end)
                ]))
            }
            #expect(throws: Service.Failure.invalidTimestamps) {
                try Service.makeOutput([result([TranscriptionSegment(start: start, end: end, text: "")])],
                                       totalSamples: 160_000, sourceTranscriptRevision: 0)
            }
        }
    }

    @Test("Nonempty speech still requires a real positive segment interval")
    func zeroDurationSpeech() {
        #expect(throws: Service.Failure.invalidTimestamps) {
            try convert(TranscriptionSegment(start: 1, end: 1, text: "one", words: [word("one", 1, 1)]))
        }
    }

    @Test("Overlapping measurements and invalid probabilities drop word alignment, not transcript")
    func untrustedWords() throws {
        let cases = [
            [word("one", 0, 1.5), word("two", 1, 2)],
            [word("one", 1, 1.5), word("two", 0, 0.5)],
            [word("one", 0, 1, probability: .nan), word("two", 1, 2)],
            [word("one", 0, 1), word("two", 1, 2, probability: 1.1)],
            [word("one", 0, 1), word("two", 1, 2, probability: -0.1)],
            [word("one", 0, 1), word("two", 3, 4)]
        ]
        for words in cases {
            let segment = try convert(TranscriptionSegment(start: 0, end: 2, text: "one two", words: words))
            #expect(segment.text == "one two")
            #expect(segment.timedRuns == nil)
        }
    }

    @Test("Measured words clip at segment edges without fabricating duration")
    func clipping() throws {
        let segment = try convert(TranscriptionSegment(start: 1, end: 2, text: "one two", words: [
            word("one", 0.5, 1.5), word("two", 1.5, 2.5)
        ]))
        #expect(segment.timedRuns?.map(\.startMs) == [1_000, 1_500])
        #expect(segment.timedRuns?.map(\.endMs) == [1_500, 2_000])
        let narrow = try convert(TranscriptionSegment(start: 0, end: 1, text: "one", words: [word("one", 0, 0.0001)]))
        #expect(narrow.timedRuns == nil)
    }

    @Test("The exact sample boundary caps segments and words, including a fractional millisecond tail")
    func recordingBoundary() throws {
        let segment = try convert(TranscriptionSegment(start: 0.5, end: 30, text: "tail", words: [word("tail", 0.5, 30)]),
                                  totalSamples: 16_015)
        #expect(segment.startMs == 500)
        #expect(segment.endMs == 1_000)
        #expect(segment.timedRuns?.first?.endMs == 1_000)
        #expect(segment.endMs * 16 <= 16_015)
        for start in [Float(1), 2, .greatestFiniteMagnitude] {
            #expect(throws: Service.Failure.invalidTimestamps) {
                try convert(TranscriptionSegment(start: start, end: start == .greatestFiniteMagnitude ? .infinity : start + 1,
                                                text: "past end"), totalSamples: 16_000)
            }
        }
        #expect(throws: Service.Failure.invalidTimestamps) {
            try convert(TranscriptionSegment(start: 0, end: 0.0001, text: "too short"), totalSamples: 1)
        }
        #expect(throws: Service.Failure.invalidTimestamps) {
            try convert(TranscriptionSegment(start: 0, end: .greatestFiniteMagnitude, text: "corrupt tail"),
                        totalSamples: 16_000)
        }
        // The allowed padded endpoint is relative to the SDK window's seek,
        // not the recording length or result count. Never offset it twice.
        let local = TranscriptionSegment(start: 0.5, end: 30, text: "tail", words: [word("tail", 0.5, 30)])
        let absolute = TranscriptionUtilities.updateSegmentTimings(segment: local, seekOffsetIndex: 480_000)
        let tail = try convert(absolute, totalSamples: 496_015)
        #expect(tail.startMs == 30_500)
        #expect(tail.endMs == 31_000)
        #expect(tail.timedRuns?.first?.endMs == 31_000)
        var corrupt = absolute
        corrupt.end = 61
        #expect(throws: Service.Failure.invalidTimestamps) { try convert(corrupt, totalSamples: 496_015) }
        for seek in [-1, 496_016] {
            var outside = absolute
            outside.seek = seek
            #expect(throws: Service.Failure.invalidTimestamps) { try convert(outside, totalSamples: 496_015) }
        }
    }

    @Test("Local window times and long incremental offsets keep their measured Float precision")
    func roundedWindowOffsets() throws {
        let chunkOffset = 288_000_000 // five hours, within the saved-audio limit
        let samples = Int64(chunkOffset + 496_000)
        for localSeek in [123_455, 319_999, 479_999] {
            let offset = Float(localSeek) / 16_000
            let local = TranscriptionSegment(seek: localSeek, start: offset + 0.5, end: offset + 30, text: "tail")
            // Match SegmentSeeker's local arithmetic followed by the SDK's
            // incremental chunk offset, rather than recomputing absolute times.
            let absolute = TranscriptionUtilities.updateSegmentTimings(segment: local, seekOffsetIndex: chunkOffset)
            let segment = try convert(absolute, totalSamples: samples)
            #expect(segment.text == "tail")
            #expect(segment.startMs == Int64((Double(absolute.start) * 1_000).rounded(.down)))
            #expect(segment.endMs == samples / 16)
            #expect(segment.timedRuns == nil)
        }
    }

    @Test("Revision overflow and invalid sample totals are rejected without a partial result")
    func invalidResultBoundary() throws {
        for revision in [-1, Int.max] {
            #expect(throws: Service.Failure.invalidRevision) {
                try Service.makeOutput([], totalSamples: 16_000, sourceTranscriptRevision: revision)
            }
        }
        for samples in [Int64(-1), Int64.max] {
            #expect(throws: Service.Failure.invalidManifest) {
                try Service.makeOutput([], totalSamples: samples, sourceTranscriptRevision: 0)
            }
        }
    }

    @Test("Thirty-minute WAV export trims FLAC overlaps and leaves saved bytes unchanged")
    func longExport() async throws {
        let fixture = try AudioFixture(totalSamples: 30 * 60 * 16_000 + 17)
        defer { fixture.remove() }
        let before = try fixture.sourceDigests()
        let wavParent = try await Service.withExportedWAV(manifest: fixture.manifest, rootURL: fixture.root,
                                                         temporaryRoot: fixture.temporary) { url in
            let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            #expect(audio.length == fixture.manifest.totalSamples)
            let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(Int64(size) <= fixture.manifest.totalSamples * 2 + 4_096)
            let probes: [Int64] = [0, 9_600_000 - 3, 19_200_000 - 3, 28_800_000 - 3, 28_800_000 + 14]
            for start in probes {
                audio.framePosition = start
                let count = AVAudioFrameCount(min(8, audio.length - start))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count))
                try audio.read(into: buffer, frameCount: count)
                #expect(buffer.frameLength == count)
                let channel = try #require(buffer.int16ChannelData?[0])
                for index in 0..<Int(count) {
                    #expect(channel[index] == Int16(truncatingIfNeeded: start + Int64(index)))
                }
            }
            return url.deletingLastPathComponent()
        }
        #expect(!FileManager.default.fileExists(atPath: wavParent.path))
        #expect(try fixture.sourceDigests() == before)
    }

    @Test("Export parent is removed after inference failure, cancellation, and truncated source audio")
    func cleanupOnFailure() async throws {
        let fixture = try AudioFixture(totalSamples: 32_000)
        defer { fixture.remove() }
        let before = try fixture.sourceDigests()
        await #expect(throws: Service.Failure.transcriptionFailed) {
            try await Service.withExportedWAV(manifest: fixture.manifest, rootURL: fixture.root,
                                             temporaryRoot: fixture.temporary) { _ -> Bool in
                throw Service.Failure.transcriptionFailed
            }
        }
        #expect(try fixture.temporaryContents().isEmpty)
        let cancelled = Task {
            try await Service.withExportedWAV(manifest: fixture.manifest, rootURL: fixture.root,
                                             temporaryRoot: fixture.temporary) { _ -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try fixture.temporaryContents().isEmpty)
        #expect(try fixture.sourceDigests() == before)
        // Valid timeline metadata, but the saved part does not contain enough frames.
        let truncated = MeetingAudioManifest(relativeDirectory: "audio", sampleRate: 16_000, totalSamples: 48_000,
            parts: [MeetingAudioPartManifest(fileName: "part-00.flac", partIndex: 0, partStartSample: 0,
                                            ownedStartSample: 0, ownedEndSample: 48_000)])
        await #expect(throws: Service.Failure.audioUnavailable) {
            try await Service.withExportedWAV(manifest: truncated, rootURL: fixture.root,
                                             temporaryRoot: fixture.temporary) { _ in
                Issue.record("Truncated saved audio must not reach transcription")
                return false
            }
        }
        #expect(try fixture.temporaryContents().isEmpty)
        #expect(try fixture.sourceDigests() == before)
    }

    @Test("Discontinuous owned ranges are rejected instead of shifting the logical clock")
    func invalidManifest() async throws {
        let fixture = try AudioFixture(totalSamples: 16_000)
        defer { fixture.remove() }
        let invalid = MeetingAudioManifest(relativeDirectory: "audio", sampleRate: 16_000, totalSamples: 16_000,
            parts: [MeetingAudioPartManifest(fileName: "part-00.flac", partIndex: 0, partStartSample: 0,
                                            ownedStartSample: 1, ownedEndSample: 16_001)])
        await #expect(throws: Service.Failure.invalidManifest) {
            try await Service.withExportedWAV(manifest: invalid, rootURL: fixture.root,
                                             temporaryRoot: fixture.temporary) { _ in
                Issue.record("Invalid manifest must not reach transcription")
                return false
            }
        }
        #expect(try fixture.temporaryContents().isEmpty)
    }

    private struct AudioFixture: Sendable {
        let root: URL
        let temporary: URL
        let manifest: MeetingAudioManifest

        @MainActor
        init(totalSamples: Int64) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offline-tests-\(UUID().uuidString)")
            root = directory
            temporary = directory.appendingPathComponent("temporary")
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let writer = try MeetingFLACPartWriter(directory: directory.appendingPathComponent("audio"))
                let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                       channels: 1, interleaved: true))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536))
                let channel = try #require(buffer.int16ChannelData?[0])
                for index in 0..<65_536 { channel[index] = Int16(truncatingIfNeeded: index) }
                var written: Int64 = 0
                while written < totalSamples {
                    buffer.frameLength = AVAudioFrameCount(min(65_536, totalSamples - written))
                    try writer.append(buffer)
                    written += Int64(buffer.frameLength)
                }
                _ = try writer.finish()
                manifest = writer.manifest(relativeDirectory: "audio")
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        @MainActor
        func sourceDigests() throws -> [Data] {
            try manifest.parts.map { part in
                let bytes = try Data(contentsOf: root.appendingPathComponent("audio").appendingPathComponent(part.fileName))
                return Data(SHA256.hash(data: bytes))
            }
        }

        func temporaryContents() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
