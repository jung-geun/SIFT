import AVFoundation
import Foundation
import Testing
@testable import todo

@Suite("Grouped meeting audio playback")
@MainActor
struct MeetingGroupAudioPlaybackTests {
    private struct Fixture {
        let manifest: MeetingAudioManifest
        let directory: URL
        var trackID: String { directory.lastPathComponent }
        var files: [URL] {
            manifest.parts.map { directory.appendingPathComponent("audio").appendingPathComponent($0.fileName) }
        }
    }

    /// Use the production FLAC writer, including its real rotation/overlap policy.
    /// Unique directories also isolate the process-wide waveform cache.
    private func fixture(count: Int, sample: (Int) -> Int16) throws -> Fixture {
        let id = UUID().uuidString.lowercased()
        let directory = AppDataContainer.meetingDirectory().appendingPathComponent(id, isDirectory: true)
        do {
            let writer = try MeetingFLACPartWriter(directory: directory.appendingPathComponent("audio"))
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
            ))
            var offset = 0
            while offset < count {
                let frames = min(8_000, count - offset)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                let channel = try #require(buffer.int16ChannelData?[0])
                for index in 0..<frames { channel[index] = sample(offset + index) }
                try writer.append(buffer)
                offset += frames
            }
            _ = try writer.finish()
            return Fixture(manifest: writer.manifest(relativeDirectory: "\(id)/audio"), directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func record(_ fixture: Fixture, groupID: String?, kind: String? = "microphone", offset: Int64 = 0) throws -> MeetingRecord {
        let record = MeetingRecord(meetingID: fixture.trackID)
        record.parentMeetingID = groupID
        record.audioTrackKindRaw = kind
        record.audioTrackStartSample = offset
        try record.update(audioManifest: fixture.manifest)
        return record
    }

    private func source(_ fixture: Fixture, at offset: Int64 = 0) -> MeetingGroupAudioPlaybackPlan.Source {
        .init(trackID: fixture.trackID, manifest: fixture.manifest, startSample: offset)
    }

    private func replacing(
        _ manifest: MeetingAudioManifest, directory: String? = nil, rate: Int64? = nil,
        total: Int64? = nil, parts: [MeetingAudioPartManifest]? = nil
    ) -> MeetingAudioManifest {
        MeetingAudioManifest(
            relativeDirectory: directory ?? manifest.relativeDirectory,
            sampleRate: rate ?? manifest.sampleRate,
            totalSamples: total ?? manifest.totalSamples,
            parts: parts ?? manifest.parts
        )
    }

    private func outputFormat() throws -> AVAudioFormat {
        try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
    }

    private func samples(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Bounds every request and fails on premature EOF rather than spinning.
    private func read(_ cursor: any MeetingPCMStreamCursor, count: Int, chunk: Int64 = 257) throws -> [Float] {
        let format = try outputFormat()
        var result: [Float] = []
        while result.count < count {
            let requested = min(chunk, Int64(count - result.count))
            let buffer = try #require(try cursor.nextPCMBuffer(maxFrames: requested, outputFormat: format))
            #expect(buffer.frameLength > 0)
            #expect(Int64(buffer.frameLength) <= requested)
            guard buffer.frameLength > 0 else { break }
            result.append(contentsOf: try samples(buffer))
        }
        #expect(result.count == count)
        return result
    }

    @Test("make trusts only known source kinds belonging to the requested group")
    func trustedPlanEligibility() throws {
        let audio = try fixture(count: 32) { Int16(1_000 + $0) }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let groupID = UUID().uuidString.lowercased()
        let mic = try record(audio, groupID: groupID, offset: 7)
        let app = try record(audio, groupID: groupID, kind: "application", offset: 101)
        app.meetingID = "application"
        let screen = try record(audio, groupID: groupID, kind: "screen", offset: 57)
        screen.meetingID = "screen"
        let unknown = try record(audio, groupID: groupID, kind: "future-source", offset: 0)
        unknown.meetingID = "unknown"
        let legacy = try record(audio, groupID: groupID, kind: "legacyMixed", offset: 0)
        legacy.meetingID = "legacy"
        let untyped = try record(audio, groupID: groupID, kind: nil)
        untyped.meetingID = "untyped"
        let foreign = try record(audio, groupID: UUID().uuidString.lowercased())
        foreign.meetingID = "foreign"
        let standalone = try record(audio, groupID: nil)
        standalone.meetingID = "standalone"
        let missing = MeetingRecord(meetingID: "missing")
        missing.parentMeetingID = groupID
        missing.audioTrackKindRaw = "microphone"
        let records = [app, unknown, foreign, legacy, missing, mic, untyped, standalone, screen]
        let before = records.map { $0.persistenceSnapshot() }

        let plan = try MeetingGroupAudioPlaybackPlan.make(tracks: records, groupID: groupID)
        #expect(plan.sources.map(\.trackID) == [mic.meetingID, screen.meetingID, app.meetingID])
        #expect(plan.sources.map(\.startSample) == [7, 57, 101])
        #expect(plan.sampleRate == 16_000)
        #expect(plan.totalSamples == 133)
        #expect(!plan.isComplete)
        #expect(plan.excludedSources == [
            .init(trackID: "foreign", reason: .notInGroup),
            .init(trackID: "legacy", reason: .unknownTiming),
            .init(trackID: "missing", reason: .missingAudio),
            .init(trackID: "standalone", reason: .notInGroup),
            .init(trackID: "unknown", reason: .unknownTiming),
            .init(trackID: "untyped", reason: .unknownTiming)
        ])
        #expect(records.map { $0.persistenceSnapshot() } == before)
        #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.noAlignedSources) {
            try MeetingGroupAudioPlaybackPlan.make(tracks: [unknown, legacy, foreign, missing], groupID: groupID)
        }
        let complete = try MeetingGroupAudioPlaybackPlan.make(tracks: [app, mic], groupID: groupID)
        #expect(complete.isComplete)
    }

    @Test("known aligned corrupt metadata fails instead of silently dropping a source")
    func corruptRecordManifest() throws {
        let audio = try fixture(count: 32) { _ in 1_000 }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let groupID = UUID().uuidString.lowercased()
        let valid = try record(audio, groupID: groupID)
        let corrupt = try record(audio, groupID: groupID)
        corrupt.meetingID = "corrupt"
        corrupt.manifestData = Data("not a manifest".utf8)
        #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.invalidSource("corrupt")) {
            try MeetingGroupAudioPlaybackPlan.make(tracks: [valid, corrupt], groupID: groupID)
        }
    }

    @Test("plan rejects malformed bounds, rates, overflow and unsafe paths before decoding")
    func invalidPlans() throws {
        let audio = try fixture(count: 32) { Int16($0) }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let manifest = audio.manifest
        func part(_ index: Int = 0, file: String = "part-00.flac", physical: Int64 = 0,
                  start: Int64 = 0, end: Int64 = 32) -> MeetingAudioPartManifest {
            .init(fileName: file, partIndex: index, partStartSample: physical,
                  ownedStartSample: start, ownedEndSample: end)
        }
        let malformed = [
            replacing(manifest, rate: 0), replacing(manifest, rate: -1),
            replacing(manifest, rate: 44_100), replacing(manifest, total: 0),
            replacing(manifest, total: -1), replacing(manifest, total: .max),
            replacing(manifest, parts: []), replacing(manifest, parts: [part(1)]),
            replacing(manifest, parts: [part(), part()]),
            replacing(manifest, parts: [part(physical: -1)]),
            replacing(manifest, parts: [part(physical: 1)]),
            replacing(manifest, parts: [part(start: -1)]),
            replacing(manifest, parts: [part(end: 0)]),
            replacing(manifest, parts: [part(end: 33)]),
            replacing(manifest, parts: [part(end: 31)]),
            replacing(manifest, parts: [part(end: 16), part(1, start: 17)]),
            replacing(manifest, parts: [part(end: 17), part(1, start: 16)]),
            replacing(manifest, parts: [part(physical: .min, start: .min, end: .max)])
        ] + ["", "/absolute/audio", "../audio", "a/../audio", "a//audio", "a/./audio", "a\\audio", "a/\0audio"].map {
            replacing(manifest, directory: $0)
        } + ["", "../part.flac", "/part.flac", "nested/part.flac", "..", "part\\00.flac", "part\0.flac"].map {
            replacing(manifest, parts: [part(file: $0)])
        }
        for invalid in malformed {
            #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.invalidSource(audio.trackID)) {
                try MeetingGroupAudioPlaybackPlan(sources: [
                    .init(trackID: audio.trackID, manifest: invalid, startSample: 0)
                ])
            }
        }
        for offset in [Int64(-1), .min, .max, MeetingMediaTimeline.maximumSamples - 31] {
            #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.invalidSource(audio.trackID)) {
                try MeetingGroupAudioPlaybackPlan(sources: [source(audio, at: offset)])
            }
        }
        #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.invalidSource(audio.trackID)) {
            try MeetingGroupAudioPlaybackPlan(sources: [source(audio), source(audio)])
        }
        #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.invalidSource("")) {
            try MeetingGroupAudioPlaybackPlan(sources: [.init(trackID: "", manifest: manifest, startSample: 0)])
        }
        #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.noAlignedSources) {
            try MeetingGroupAudioPlaybackPlan(sources: [])
        }
    }

    @Test("mix preserves solo amplitude, exact gaps and overlap sums across arbitrary chunks")
    func mixedTimelineAndSeek() throws {
        let first = try fixture(count: 19) { Int16(1_000 + $0 * 100) }
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let second = try fixture(count: 13) { Int16(-500 + $0 * 50) }
        defer { try? FileManager.default.removeItem(at: second.directory) }
        let late = try fixture(count: 7) { Int16(4_000 + $0 * 10) }
        defer { try? FileManager.default.removeItem(at: late.directory) }
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [
            source(late, at: 37), source(second, at: 11), source(first, at: 3)
        ])
        let expected: [Float] = (0..<44).map { parent in
            var sum = 0
            if (3..<22).contains(parent) { sum += 1_000 + (parent - 3) * 100 }
            if (11..<24).contains(parent) { sum += -500 + (parent - 11) * 50 }
            if (37..<44).contains(parent) { sum += 4_000 + (parent - 37) * 10 }
            return Float(sum) / 32_768
        }
        let format = try outputFormat()
        for chunk in [Int64(1), 7, 65_536] {
            let cursor = try MeetingGroupAudioCursor(plan: plan)
            #expect(try read(cursor, count: 44, chunk: chunk) == expected)
            #expect(try cursor.nextPCMBuffer(maxFrames: 1, outputFormat: format) == nil)
        }
        let cursor = try MeetingGroupAudioCursor(plan: plan)
        // Includes seeking backward after a decoder has already been consumed.
        // 27 is before the late source; 15 starts inside an existing overlap.
        for target in [27, 15, 3, 11, 22, 37, 0, 43] {
            try cursor.seek(toLogicalSample: Int64(target))
            #expect(try read(cursor, count: 44 - target, chunk: 5) == Array(expected[target...]))
        }
        try cursor.seek(toLogicalSample: -1)
        #expect(try read(cursor, count: 4) == Array(expected.prefix(4)))
        for end in [Int64(44), .max] {
            try cursor.seek(toLogicalSample: end)
            #expect(try cursor.nextPCMBuffer(maxFrames: 10, outputFormat: format) == nil)
        }
    }

    @Test("mix saturates after summation, not per source, and opposite phases cancel")
    func saturationAndCancellation() throws {
        let positive = try fixture(count: 64) { _ in 30_000 }
        defer { try? FileManager.default.removeItem(at: positive.directory) }
        let negative = try fixture(count: 64) { _ in -30_000 }
        defer { try? FileManager.default.removeItem(at: negative.directory) }
        func aliased(_ fixture: Fixture, _ id: String) -> MeetingGroupAudioPlaybackPlan.Source {
            .init(trackID: id, manifest: fixture.manifest, startSample: 0)
        }
        let cases: [(sources: [MeetingGroupAudioPlaybackPlan.Source], expected: Float)] = [
            ([source(positive), aliased(positive, "second-positive")], 1),
            ([source(negative), aliased(negative, "second-negative")], -1),
            ([source(positive), source(negative)], 0),
            // Clamping the first two sources before adding the third would give
            // 1 - 30000/32768, not the original positive amplitude.
            ([aliased(positive, "a"), aliased(positive, "b"), aliased(negative, "c")], Float(30_000) / 32_768)
        ]
        for item in cases {
            let plan = try MeetingGroupAudioPlaybackPlan(sources: item.sources)
            let actual = try read(MeetingGroupAudioCursor(plan: plan), count: 64, chunk: 11)
            #expect(actual == Array(repeating: item.expected, count: 64))
            #expect(actual.allSatisfy { $0.isFinite && (-1...1).contains($0) })
        }
    }

    @Test("real multipart overlap trims once and source-local playback remains equivalent without mutation")
    func multipartOwnershipAndLocalEquivalence() throws {
        let boundary = Int(MeetingMediaTimeline.ownedSamplesPerPart)
        let total = boundary + 173
        func pcm(_ index: Int) -> Int16 { Int16(index % 10_000 - 5_000) }
        let audio = try fixture(count: total, sample: pcm)
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        #expect(audio.manifest.parts.count == 2)
        let secondPart = try #require(audio.manifest.parts.last)
        #expect(secondPart.partStartSample == Int64(boundary) - MeetingMediaTimeline.overlapSamples)
        #expect(secondPart.ownedStartSample == Int64(boundary))
        let originalManifest = audio.manifest
        let originalFiles = try audio.files.map { try Data(contentsOf: $0) }
        let secondFile = try AVAudioFile(forReading: #require(audio.files.last))
        #expect(secondFile.length == MeetingMediaTimeline.overlapSamples + 173)

        let parentOffset: Int64 = 79
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [source(audio, at: parentOffset)])
        let parent = try MeetingGroupAudioCursor(plan: plan)
        let local = try MeetingLogicalAudioCursor(manifest: audio.manifest)
        let single = try MeetingGroupAudioCursor(plan: MeetingGroupAudioPlaybackPlan.single(manifest: audio.manifest))
        for start in [0, boundary - 97, boundary, boundary + 31] {
            let count = min(211, total - start)
            try parent.seek(toLogicalSample: parentOffset + Int64(start))
            try local.seek(toLogicalSample: Int64(start))
            try single.seek(toLogicalSample: Int64(start))
            let expected = (start..<(start + count)).map { Float(pcm($0)) / 32_768 }
            #expect(try read(parent, count: count, chunk: 37) == expected)
            #expect(try read(local, count: count, chunk: 41) == expected)
            #expect(try read(single, count: count, chunk: 43) == expected)
        }
        let overlay = try fixture(count: 300) { _ in 4_096 }
        defer { try? FileManager.default.removeItem(at: overlay.directory) }
        let overlayFiles = try overlay.files.map { try Data(contentsOf: $0) }
        let mixedPlan = try MeetingGroupAudioPlaybackPlan(sources: [
            source(audio, at: parentOffset),
            source(overlay, at: parentOffset + Int64(boundary - 100))
        ])
        let mixed = try MeetingGroupAudioCursor(plan: mixedPlan)
        try mixed.seek(toLogicalSample: parentOffset + Int64(boundary - 111))
        // Cross both the overlay onset and the physical FLAC rotation in a
        // single parent read; the second part's encoded pre-roll must not replay.
        let mixedExpected: [Float] = ((boundary - 111)..<(boundary + 173)).map { index in
            Float(Int(pcm(index)) + (index >= boundary - 100 ? 4_096 : 0)) / 32_768
        }
        #expect(try read(mixed, count: mixedExpected.count, chunk: 65_536) == mixedExpected)
        #expect(try overlay.files.map { try Data(contentsOf: $0) } == overlayFiles)
        #expect(audio.manifest == originalManifest)
        #expect(try audio.files.map { try Data(contentsOf: $0) } == originalFiles)
    }

    @Test("six-hour logical timelines return bounded silence and seek directly into a tiny late source")
    func boundedLongTimeline() throws {
        let audio = try fixture(count: 19) { Int16(2_000 + $0) }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let start = MeetingMediaTimeline.maximumSamples - 19
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [source(audio, at: start)])
        #expect(plan.totalSamples == MeetingMediaTimeline.maximumSamples)
        let cursor = try MeetingGroupAudioCursor(plan: plan)
        let format = try outputFormat()
        let first = try #require(try cursor.nextPCMBuffer(maxFrames: .max, outputFormat: format))
        #expect(Int64(first.frameLength) == MeetingGroupAudioCursor.chunkFrames)
        #expect(Int64(first.frameCapacity) <= MeetingGroupAudioCursor.chunkFrames)
        #expect(try samples(first).allSatisfy { $0 == 0 })
        try cursor.seek(toLogicalSample: start - 5)
        let expected = Array(repeating: Float(0), count: 5) + (0..<19).map { Float(2_000 + $0) / 32_768 }
        #expect(try read(cursor, count: 24, chunk: 7) == expected)
        #expect(try cursor.nextPCMBuffer(maxFrames: .max, outputFormat: format) == nil)
        try cursor.seek(toLogicalSample: start + 11)
        #expect(try read(cursor, count: 8) == Array(expected.suffix(8)))
    }

    @Test("corrupt or missing physical audio fails when reached instead of being mixed as silence")
    func corruptPhysicalAudio() throws {
        let audio = try fixture(count: 32) { Int16(1_000 + $0) }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let format = try outputFormat()
        let longer = replacing(audio.manifest, total: 33, parts: [
            .init(fileName: "part-00.flac", partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 33)
        ])
        let excessive = try MeetingGroupAudioPlaybackPlan(sources: [
            .init(trackID: audio.trackID, manifest: longer, startSample: 0)
        ])
        #expect(throws: Error.self) {
            let cursor = try MeetingGroupAudioCursor(plan: excessive)
            _ = try cursor.nextPCMBuffer(maxFrames: 33, outputFormat: format)
        }
        let missing = replacing(audio.manifest, parts: [
            .init(fileName: "missing.flac", partIndex: 0, partStartSample: 0, ownedStartSample: 0, ownedEndSample: 32)
        ])
        let missingPlan = try MeetingGroupAudioPlaybackPlan(sources: [
            .init(trackID: audio.trackID, manifest: missing, startSample: 10)
        ])
        let cursor = try MeetingGroupAudioCursor(plan: missingPlan)
        #expect(try read(cursor, count: 10).allSatisfy { $0 == 0 })
        #expect(throws: Error.self) {
            _ = try cursor.nextPCMBuffer(maxFrames: 1, outputFormat: format)
        }
        let file = try #require(audio.files.first)
        try Data("invalid FLAC bytes".utf8).write(to: file)
        let corruptPlan = try MeetingGroupAudioPlaybackPlan(sources: [source(audio)])
        #expect(throws: Error.self) {
            _ = try MeetingGroupAudioCursor(plan: corruptPlan).nextPCMBuffer(maxFrames: 32, outputFormat: format)
        }
    }

    /// Continuations provide an explicit happens-before relation. No sleeps,
    /// audio-session activation, microphone permission, or engine startup.
    @MainActor
    private final class ActivationGate {
        private(set) var calls = 0
        private var suspended: [Int: CheckedContinuation<Void, Never>] = [:]
        private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

        func activate() async {
            calls += 1
            let call = calls
            await withCheckedContinuation { continuation in
                suspended[call] = continuation
                let ready = observers.filter { $0.0 <= calls }
                observers.removeAll { $0.0 <= calls }
                for (_, observer) in ready { observer.resume() }
            }
        }

        func waitUntilSuspended(_ call: Int) async {
            if suspended[call] != nil { return }
            await withCheckedContinuation { observers.append((call, $0)) }
        }

        func release(_ call: Int) {
            suspended.removeValue(forKey: call)?.resume()
        }

        func releaseAll() {
            let continuations = Array(suspended.values)
            suspended.removeAll()
            for continuation in continuations { continuation.resume() }
        }
    }

    @Test("output availability requires a finite positive hardware rate and nonzero channels")
    func outputRouteAvailability() {
        for rate in [0.0, -1, .nan, .infinity, -.infinity] {
            #expect(!MeetingAudioPlaybackController.OutputRoute(sampleRate: rate, channelCount: 1).isAvailable)
        }
        for rate in [44_100.0, 48_000] {
            #expect(!MeetingAudioPlaybackController.OutputRoute(sampleRate: rate, channelCount: 0).isAvailable)
            for channels in [AVAudioChannelCount(1), 2, 8] {
                #expect(MeetingAudioPlaybackController.OutputRoute(sampleRate: rate, channelCount: channels).isAvailable)
            }
        }
        #expect(!MeetingAudioPlaybackController.OutputRoute(sampleRate: 0, channelCount: 0).isAvailable)
    }

    /// Valid metadata with no physical file: route/activation failures must be
    /// returned before any decoder can try to open this source.
    private func routeBoundaryPlan() throws -> MeetingGroupAudioPlaybackPlan {
        try .single(manifest: MeetingAudioManifest(
            relativeDirectory: "route-boundary/audio", sampleRate: 44_100, totalSamples: 32,
            parts: [.init(fileName: "part-00.flac", partIndex: 0, partStartSample: 0,
                          ownedStartSample: 0, ownedEndSample: 32)]
        ))
    }

    @Test("unavailable output fails before graph connections or decoding, without automatic retries")
    func unavailableOutputBeforeDecoding() async throws {
        var events: [String] = []
        var engines: [AVAudioEngine] = []
        let controller = MeetingAudioPlaybackController(
            activateSession: { events.append("activate") },
            makeEngine: {
                events.append("engine")
                let engine = AVAudioEngine()
                engines.append(engine)
                return engine
            },
            outputRoute: { _ in
                events.append("route")
                return .init(sampleRate: 0, channelCount: 0)
            }
        )
        defer { controller.stop() }
        let plan = try routeBoundaryPlan()
        // Only a second explicit user request may attempt a new activated graph.
        for attempt in 1...2 {
            do {
                try await controller.play(plan: plan)
                Issue.record("Unavailable output unexpectedly started playback")
            } catch MeetingAudioPlaybackController.PlaybackError.operation(let operation, let underlying) {
                #expect(operation == "outputRoute")
                guard let routeError = underlying as? MeetingAudioPlaybackController.OutputRouteError,
                      case .unavailable(let route) = routeError else {
                    Issue.record("Missing output-route failure details")
                    return
                }
                #expect(route == .init(sampleRate: 0, channelCount: 0))
            }
            #expect(events == Array(repeating: ["activate", "engine", "route"], count: attempt).flatMap { $0 })
            #expect(engines.count == attempt)
            #expect(!controller.hasPlaybackResources)
            #expect(!controller.isPreparingPlayback)
            #expect(!controller.isPlaying)
            #expect(!controller.isPaused)
            #expect(controller.errorMessage == nil)
        }
        #expect(engines[0] !== engines[1])
        #expect(engines.allSatisfy { engine in
            !engine.isRunning && !engine.attachedNodes.contains { $0 is AVAudioPlayerNode || $0 is AVAudioUnitEQ }
        })
    }

    @Test("activation failure propagates without creating or probing an engine")
    func activationFailureBeforeOutputProbe() async throws {
        let failure = NSError(domain: "PlaybackActivationBoundary", code: 73)
        var engineCalls = 0
        var routeCalls = 0
        let controller = MeetingAudioPlaybackController(
            activateSession: { throw failure },
            makeEngine: { engineCalls += 1; return AVAudioEngine() },
            outputRoute: { _ in routeCalls += 1; return .init(sampleRate: 48_000, channelCount: 2) }
        )
        defer { controller.stop() }
        do {
            try await controller.play(plan: routeBoundaryPlan())
            Issue.record("Activation failure unexpectedly started playback")
        } catch MeetingAudioPlaybackController.PlaybackError.operation(let operation, let underlying) {
            #expect(operation == "activateSession")
            #expect((underlying as NSError) === failure)
        }
        #expect(engineCalls == 0)
        #expect(routeCalls == 0)
        #expect(!controller.isPreparingPlayback)
        #expect(!controller.hasPlaybackResources)
    }

    @Test("task cancellation during activation fences engine creation and output probing")
    func cancellationBeforeOutputProbe() async throws {
        let gate = ActivationGate()
        var engineCalls = 0
        var routeCalls = 0
        let controller = MeetingAudioPlaybackController(
            activateSession: { await gate.activate() },
            makeEngine: { engineCalls += 1; return AVAudioEngine() },
            outputRoute: { _ in routeCalls += 1; return .init(sampleRate: 48_000, channelCount: 2) }
        )
        defer { controller.stop(); gate.releaseAll() }
        let plan = try routeBoundaryPlan()
        let playback = Task { try await controller.play(plan: plan) }
        await gate.waitUntilSuspended(1)
        #expect(engineCalls == 0)
        #expect(routeCalls == 0)
        playback.cancel()
        gate.release(1)
        await #expect(throws: CancellationError.self) { try await playback.value }
        #expect(engineCalls == 0)
        #expect(routeCalls == 0)
        #expect(!controller.isPreparingPlayback)
        #expect(!controller.hasPlaybackResources)
    }

    /// Manual rendering exercises real node connections without acquiring a
    /// device route, activating AVAudioSession, or consuming wall-clock audio.
    private func offlineEngine(rate: Double, channels: AVAudioChannelCount) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false
        ))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        return engine
    }

    @Test("resume and configuration changes rebuild an activated graph and ignore stale engine events")
    func routeGraphLifetime() async throws {
        let audio = try fixture(count: 3_200) { _ in 1_000 }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let engines = try [
            offlineEngine(rate: 44_100, channels: 1),
            offlineEngine(rate: 48_000, channels: 2),
            offlineEngine(rate: 44_100, channels: 2)
        ]
        var activations = 0
        var creations = 0
        let controller = MeetingAudioPlaybackController(
            activateSession: { activations += 1 },
            makeEngine: {
                #expect(activations == creations + 1)
                let engine = engines[creations]
                creations += 1
                return engine
            }
        )
        defer { controller.stop() }
        #expect(creations == 0)
        controller.outputLevelPercent = 200
        try await controller.play(manifest: audio.manifest)
        #expect(controller.isPlaying)
        controller.seek(toProgress: 0.25)
        controller.pause()
        #expect(controller.isPaused)
        try await controller.play(manifest: audio.manifest)
        #expect(activations == 2)
        #expect(creations == 2)
        #expect(!engines[0].isRunning)
        #expect(engines[1].isRunning)
        #expect(controller.isPlaying)
        #expect(!controller.isPaused)
        #expect(controller.playbackProgress == 0.25)
        let equalizer = try #require(engines[1].attachedNodes.compactMap { $0 as? AVAudioUnitEQ }.first)
        #expect(abs(equalizer.globalGain - 6.0206) < 0.001)

        // Exercise the main-actor notification handler directly; no sleeps or
        // assumptions about when NotificationCenter's internal queue delivers.
        controller.handleConfigurationChange(for: engines[0])
        #expect(controller.isPlaying)
        #expect(controller.hasPlaybackResources)
        controller.handleConfigurationChange(for: engines[1])
        #expect(!controller.isPlaying)
        #expect(!controller.hasPlaybackResources)
        #expect(controller.playbackProgress == 0.25)
        #expect(activations == 2)
        #expect(creations == 2)
        try await controller.play(manifest: audio.manifest)
        #expect(activations == 3)
        #expect(creations == 3)
        #expect(controller.isPlaying)
        #expect(controller.playbackProgress == 0.25)
    }

    @Test("stop invalidates suspended activation and returns CancellationError without playback resources")
    func stopDuringActivation() async throws {
        let audio = try fixture(count: 32) { _ in 1_000 }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let gate = ActivationGate()
        let controller = MeetingAudioPlaybackController(activateSession: { await gate.activate() })
        defer {
            controller.stop()
            gate.releaseAll()
        }
        controller.seek(toProgress: 0.25, totalMilliseconds: 2_000)
        let playback = Task { try await controller.play(manifest: audio.manifest) }
        await gate.waitUntilSuspended(1)
        #expect(gate.calls == 1)
        #expect(controller.isPreparingPlayback)
        #expect(!controller.hasPlaybackResources)
        #expect(!controller.isPlaying)

        controller.stop()
        #expect(!controller.isPreparingPlayback)
        gate.release(1)
        await #expect(throws: CancellationError.self) { try await playback.value }
        #expect(!controller.hasPlaybackResources)
        #expect(!controller.isPreparingPlayback)
        #expect(!controller.isPlaying)
        #expect(!controller.isPaused)
        #expect(controller.playbackProgress == 0)
        #expect(controller.playbackMilliseconds == 0)
        #expect(controller.errorMessage == nil)
    }

    @Test("a second play is accepted after stop and old completion cannot clear its preparation or seek")
    func supersededActivationCannotClearNewPlay() async throws {
        let audio = try fixture(count: 32) { _ in 2_000 }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [source(audio, at: 160)])
        let gate = ActivationGate()
        let controller = MeetingAudioPlaybackController(activateSession: { await gate.activate() })
        defer {
            controller.stop()
            gate.releaseAll()
        }
        let first = Task { try await controller.play(plan: plan) }
        await gate.waitUntilSuspended(1)
        controller.stop()
        let second = Task { try await controller.play(plan: plan) }
        // Keep BOTH activations suspended: neither request can start an engine.
        await gate.waitUntilSuspended(2)
        #expect(gate.calls == 2)
        #expect(controller.isPreparingPlayback)
        #expect(!controller.hasPlaybackResources)
        controller.seek(toProgress: 0.625, totalMilliseconds: 8_000)

        gate.release(1)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(controller.isPreparingPlayback)
        #expect(!controller.hasPlaybackResources)
        #expect(!controller.isPlaying)
        #expect(controller.playbackProgress == 0.625)
        #expect(controller.playbackMilliseconds == 5_000)
        #expect(controller.errorMessage == nil)

        controller.stop()
        gate.release(2)
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(!controller.isPreparingPlayback)
        #expect(!controller.hasPlaybackResources)
        #expect(!controller.isPlaying)
        #expect(!controller.isPaused)
        #expect(controller.playbackProgress == 0)
        #expect(controller.playbackMilliseconds == 0)
        #expect(controller.errorMessage == nil)
    }

    @Test("make rejects impossible known offsets but excludes foreign clocks and empty recordings")
    func trustedOffsetBoundsAndEmptyAudio() throws {
        let audio = try fixture(count: 32) { _ in 1_000 }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let groupID = UUID().uuidString.lowercased()
        let valid = try record(audio, groupID: groupID)
        for offset in [Int64(-1), .min, .max, MeetingMediaTimeline.maximumSamples + 1,
                       MeetingMediaTimeline.maximumSamples - 31] {
            let invalid = try record(audio, groupID: groupID, offset: offset)
            invalid.meetingID = "invalid-offset"
            #expect(throws: MeetingGroupAudioPlaybackPlan.PlanError.invalidSource("invalid-offset")) {
                try MeetingGroupAudioPlaybackPlan.make(tracks: [valid, invalid], groupID: groupID)
            }
            invalid.parentMeetingID = "another-group"
            let plan = try MeetingGroupAudioPlaybackPlan.make(tracks: [invalid, valid], groupID: groupID)
            #expect(plan.sources.map(\.trackID) == [valid.meetingID])
            #expect(plan.excludedSources == [.init(trackID: "invalid-offset", reason: .notInGroup)])
        }
        let empty = try record(audio, groupID: groupID)
        empty.meetingID = "empty-recording"
        try empty.update(audioManifest: replacing(audio.manifest, total: 0, parts: []))
        let plan = try MeetingGroupAudioPlaybackPlan.make(tracks: [valid, empty], groupID: groupID)
        #expect(plan.excludedSources == [.init(trackID: "empty-recording", reason: .missingAudio)])
        #expect(plan.totalSamples == 32)
    }

    @Test("waveform follows parent offsets and gaps and its cache distinguishes equal-duration plans")
    func waveformOffsetsAndCache() throws {
        let first = try fixture(count: 1_600) { _ in 8_192 }
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let last = try fixture(count: 1_600) { _ in 8_192 }
        defer { try? FileManager.default.removeItem(at: last.directory) }
        let original = try MeetingGroupAudioPlaybackPlan(sources: [source(first), source(last, at: 6_400)])
        let shifted = try MeetingGroupAudioPlaybackPlan(sources: [source(first, at: 3_200), source(last, at: 6_400)])
        #expect(original.totalSamples == shifted.totalSamples)
        let firstWave = try MeetingWaveformGenerator.generate(plan: original, bucketCount: 5)
        #expect(firstWave.totalSamples == 8_000)
        #expect(firstWave.buckets == [1, 0, 0, 0, 1])
        let shiftedWave = try MeetingWaveformGenerator.generate(plan: shifted, bucketCount: 5)
        #expect(shiftedWave.totalSamples == 8_000)
        #expect(shiftedWave.buckets == [0, 0, 1, 0, 1])
        #expect(shiftedWave != firstWave)
        #expect(try MeetingWaveformGenerator.generate(plan: original, bucketCount: 5) == firstWave)
        #expect(try MeetingWaveformGenerator.generate(plan: shifted, bucketCount: 5) == shiftedWave)
        let finer = try MeetingWaveformGenerator.generate(plan: original, bucketCount: 10)
        #expect(finer.buckets == [1, 1, 0, 0, 0, 0, 0, 0, 1, 1])
        let local = try MeetingWaveformGenerator.generate(manifest: first.manifest, bucketCount: 5)
        let single = try MeetingGroupAudioPlaybackPlan.single(manifest: first.manifest)
        #expect(try MeetingWaveformGenerator.generate(plan: single, bucketCount: 5) == local)
    }

    @Test("waveform measures mixed PCM cancellation rather than the union of source peaks")
    func waveformCancellation() throws {
        let positive = try fixture(count: 1_600) { _ in 12_000 }
        defer { try? FileManager.default.removeItem(at: positive.directory) }
        let negative = try fixture(count: 1_600) { _ in -12_000 }
        defer { try? FileManager.default.removeItem(at: negative.directory) }
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [source(positive), source(negative)])
        let waveform = try MeetingWaveformGenerator.generate(plan: plan, bucketCount: 10)
        #expect(waveform.totalSamples == 1_600)
        #expect(waveform.buckets == Array(repeating: Float(0), count: 10))
    }

    @Test("a cached group waveform still honors task cancellation")
    func cancelledGroupWaveformCacheRead() async throws {
        let audio = try fixture(count: 1_600) { _ in 8_192 }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [source(audio, at: 1_600)])
        _ = try MeetingWaveformGenerator.generate(plan: plan, bucketCount: 4)
        let task = Task { try MeetingWaveformGenerator.generate(plan: plan, bucketCount: 4) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("offline scheduler delivers mixed PCM, seeks on the parent clock and cancels permanently")
    func offlineMixedScheduler() async throws {
        let first = try fixture(count: 32_000) { _ in 8_192 }
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let second = try fixture(count: 32_000) { _ in 4_096 }
        defer { try? FileManager.default.removeItem(at: second.directory) }
        let plan = try MeetingGroupAudioPlaybackPlan(sources: [source(first), source(second, at: 16_000)])
        let format = try outputFormat()
        let engine = AVAudioEngine()
        // Enter offline mode before touching the mixer, which otherwise opens device I/O.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        defer {
            node.stop()
            engine.stop()
        }

        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var finishedEpoch: Int?
            private var failed = false
            func record(_ event: MeetingPlaybackStreamScheduler.Event) {
                lock.lock()
                defer { lock.unlock() }
                switch event {
                case .finished(let epoch): finishedEpoch = epoch
                case .failed: failed = true
                }
            }
            var snapshot: (epoch: Int?, failed: Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (finishedEpoch, failed)
            }
        }
        let events = Events()
        let scheduler = MeetingPlaybackStreamScheduler(
            cursor: try MeetingGroupAudioCursor(plan: plan), node: node, format: format
        )
        scheduler.onEvent = { events.record($0) }
        defer { scheduler.cancel() }
        // Mirrors the controller's initial armed seek, before engine startup.
        try scheduler.seek(toLogicalSample: 16_000, resumePlaying: false)
        try engine.start()
        node.play()
        let render = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024))
        #expect(try engine.renderOffline(1_024, to: render) == .success)
        #expect(try samples(render).contains { abs($0 - 0.375) < 0.0001 })

        let overlapEpoch = scheduler.currentEpoch()
        try scheduler.seek(toLogicalSample: 0, resumePlaying: true)
        #expect(scheduler.currentEpoch() > overlapEpoch)
        #expect(try engine.renderOffline(1_024, to: render) == .success)
        #expect(try samples(render).contains { abs($0 - 0.25) < 0.0001 })

        try scheduler.seek(toLogicalSample: 40_000, resumePlaying: true)
        let finalEpoch = scheduler.currentEpoch()
        #expect(try engine.renderOffline(1_024, to: render) == .success)
        #expect(try samples(render).contains { abs($0 - 0.125) < 0.0001 })
        var iterations = 0
        while events.snapshot.epoch != finalEpoch, !events.snapshot.failed, iterations < 100 {
            #expect(try engine.renderOffline(1_024, to: render) == .success)
            iterations += 1
            // Only the scheduler's refill queue needs a turn; never a real session.
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!events.snapshot.failed)
        #expect(events.snapshot.epoch == finalEpoch)
        scheduler.cancel()
        #expect(scheduler.currentEpoch() > finalEpoch)
        #expect(!node.isPlaying)
        #expect(scheduler.onEvent == nil)
        #expect(throws: CancellationError.self) { try scheduler.start() }
        #expect(throws: CancellationError.self) {
            try scheduler.seek(toLogicalSample: 0, resumePlaying: false)
        }
    }
}
